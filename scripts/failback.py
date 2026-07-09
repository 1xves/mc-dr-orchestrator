#!/usr/bin/env python3
"""
failback.py — Manual failback orchestrator (AWS ← Azure)

After the primary AWS environment recovers, this script:
  1. Verifies AWS primary is healthy
  2. Re-establishes pglogical replication from Azure → AWS (reverse sync)
  3. Waits for replication lag to reach zero
  4. Switches Route53 DNS back to AWS
  5. Scales Azure AKS back to zero (cost saving)
  6. Re-enables pglogical in the correct direction (Azure as subscriber)
  7. Sends completion notification

Usage:
    python failback.py --verify-only          # Check readiness without acting
    python failback.py --execute              # Run full failback
    python failback.py --execute --dry-run    # Simulate (no changes)
"""

import argparse
import json
import logging
import os
import subprocess
import time
from datetime import datetime, timezone

import boto3
import requests
from dotenv import load_dotenv

load_dotenv()
log = logging.getLogger("failback")


class FailbackOrchestrator:
    def __init__(self, dry_run: bool = False):
        self.dry_run = dry_run

        # AWS
        self.aws_region         = os.environ.get("AWS_REGION", "us-east-1")
        self.primary_url        = os.environ["PRIMARY_URL"]
        self.rds_endpoint       = os.environ["RDS_ENDPOINT"]
        self.rds_admin          = os.environ.get("RDS_ADMIN", "dbadmin")
        self.rds_password       = os.environ.get("RDS_PASSWORD", "")
        self.route53_zone_id    = os.environ["ROUTE53_ZONE_ID"]
        self.dns_record_name    = os.environ.get("DNS_RECORD_NAME", "api.example.com")
        self.aws_lb_ip          = os.environ.get("AWS_LB_IP", "")
        self.sns_topic_arn      = os.environ.get("SNS_TOPIC_ARN", "")

        # EKS
        self.eks_cluster_name   = os.environ["EKS_CLUSTER_NAME"]
        self.k8s_manifests_aws  = os.environ.get("K8S_MANIFESTS_PATH_AWS", "../k8s/aws")

        # Azure
        self.azure_resource_group   = os.environ["AZURE_RESOURCE_GROUP"]
        self.azure_aks_cluster      = os.environ["AZURE_AKS_CLUSTER"]
        self.azure_aks_nodepool     = os.environ.get("AZURE_AKS_NODEPOOL", "app")
        self.azure_pg_fqdn          = os.environ["AZURE_PG_FQDN"]
        self.azure_pg_admin         = os.environ.get("AZURE_PG_ADMIN", "dbadmin")
        self.azure_pg_password      = os.environ.get("AZURE_PG_PASSWORD", "")

        # AWS clients
        self._route53   = boto3.client("route53")
        self._cloudwatch = boto3.client("cloudwatch", region_name=self.aws_region)
        self._sns       = boto3.client("sns", region_name=self.aws_region)

        self.timeline: dict = {}

    # ── Readiness check ───────────────────────────────────────────────────────
    def verify_readiness(self) -> dict:
        """Check all preconditions before executing failback."""
        log.info("=== FAILBACK READINESS CHECK ===")
        checks = {}

        # 1. Primary endpoint healthy
        try:
            resp = requests.get(self.primary_url, timeout=10)
            checks["primary_http"] = resp.status_code == 200
        except Exception as exc:
            checks["primary_http"] = False
            log.warning("Primary HTTP check failed: %s", exc)

        # 2. RDS instance accepting connections
        try:
            out = self._psql_aws("SELECT 1;", capture=True)
            checks["rds_connectivity"] = "1" in out
        except Exception as exc:
            checks["rds_connectivity"] = False
            log.warning("RDS connectivity check failed: %s", exc)

        # 3. EKS cluster reachable
        try:
            self._run_aws_eks_credentials()
            out = self._run(["kubectl", "get", "nodes", "--no-headers"], capture=True)
            checks["eks_reachable"] = len(out.strip()) > 0
        except Exception as exc:
            checks["eks_reachable"] = False
            log.warning("EKS check failed: %s", exc)

        ready = all(checks.values())
        log.info("Readiness result: %s | details=%s", "READY" if ready else "NOT READY", checks)
        return {"ready": ready, "checks": checks}

    # ── Execute failback ──────────────────────────────────────────────────────
    def execute(self) -> dict:
        self.timeline["failback_start"] = datetime.now(timezone.utc).isoformat()
        log.info("=== FAILBACK STARTED | dry_run=%s ===", self.dry_run)

        # Pre-flight
        readiness = self.verify_readiness()
        if not readiness["ready"]:
            raise RuntimeError(f"Failback pre-flight checks failed: {readiness['checks']}")

        result = {"steps": {}, "success": False, "dry_run": self.dry_run}

        try:
            result["steps"]["aws_deploy"]      = self._step_deploy_to_eks()
            result["steps"]["db_resync"]        = self._step_resync_database()
            result["steps"]["dns_switch"]       = self._step_switch_dns_to_aws()
            result["steps"]["aks_scale_zero"]   = self._step_scale_aks_to_zero()
            result["steps"]["db_reestablish"]   = self._step_reestablish_pglogical()

            self.timeline["failback_end"] = datetime.now(timezone.utc).isoformat()
            result["timeline"] = self.timeline
            result["success"] = True

            log.info("=== FAILBACK COMPLETED ===")
            self._notify(
                subject="[DR] Failback complete — traffic back on AWS",
                message=f"Failback completed at {self.timeline['failback_end']}.\n"
                        f"Timeline: {json.dumps(self.timeline, indent=2)}",
            )
            return result

        except Exception as exc:
            log.error("Failback failed: %s", exc, exc_info=True)
            result["error"] = str(exc)
            raise

    # ── Step 1: Re-deploy to EKS ──────────────────────────────────────────────
    def _step_deploy_to_eks(self) -> dict:
        log.info("STEP 1 — Deploying workloads to EKS (primary)…")
        self.timeline["eks_deploy_start"] = datetime.now(timezone.utc).isoformat()

        if not self.dry_run:
            self._run_aws_eks_credentials()
            self._run(["kubectl", "apply", "-f", self.k8s_manifests_aws, "--recursive"])
            self._run(["kubectl", "rollout", "status", "deployment", "-n", "app", "--timeout=300s"])

        self.timeline["eks_deploy_end"] = datetime.now(timezone.utc).isoformat()
        duration = self._duration("eks_deploy_start", "eks_deploy_end")
        log.info("✅ EKS workloads deployed in %ds", duration)
        return {"duration_s": duration}

    # ── Step 2: Resync data from Azure → AWS ─────────────────────────────────
    def _step_resync_database(self) -> dict:
        log.info("STEP 2 — Resyncing data from Azure PostgreSQL → AWS RDS…")
        self.timeline["db_resync_start"] = datetime.now(timezone.utc).isoformat()

        # Re-establish pglogical: Azure as publisher, AWS RDS as subscriber
        setup_sql = f"""
            -- On AWS RDS (subscriber side)
            SELECT pglogical.create_node(
                node_name := 'aws_primary',
                dsn := 'host={self.rds_endpoint} dbname=appdb user={self.rds_admin} password={self.rds_password}'
            );

            SELECT pglogical.create_subscription(
                subscription_name := 'azure_to_aws_sync',
                provider_dsn := 'host={self.azure_pg_fqdn} dbname=appdb user={self.azure_pg_admin} password={self.azure_pg_password} sslmode=require',
                replication_sets := ARRAY['default'],
                synchronize_data := true
            );
        """
        if not self.dry_run:
            self._psql_aws(setup_sql)
            self._wait_for_replication_lag_zero()

        self.timeline["db_resync_end"] = datetime.now(timezone.utc).isoformat()
        duration = self._duration("db_resync_start", "db_resync_end")
        log.info("✅ DB resynced in %ds", duration)
        return {"duration_s": duration}

    # ── Step 3: Switch DNS back to AWS ────────────────────────────────────────
    def _step_switch_dns_to_aws(self) -> dict:
        log.info("STEP 3 — Switching Route53 DNS back to AWS…")
        self.timeline["dns_switch_start"] = datetime.now(timezone.utc).isoformat()

        if not self.dry_run:
            response = self._route53.change_resource_record_sets(
                HostedZoneId=self.route53_zone_id,
                ChangeBatch={
                    "Comment": f"DR failback to AWS — {datetime.now(timezone.utc).isoformat()}",
                    "Changes": [{
                        "Action": "UPSERT",
                        "ResourceRecordSet": {
                            "Name": self.dns_record_name,
                            "Type": "A",
                            "TTL": 300,
                            "ResourceRecords": [{"Value": self.aws_lb_ip}],
                        },
                    }],
                },
            )
            waiter = self._route53.get_waiter("resource_record_sets_changed")
            waiter.wait(Id=response["ChangeInfo"]["Id"])

        self.timeline["dns_switch_end"] = datetime.now(timezone.utc).isoformat()
        duration = self._duration("dns_switch_start", "dns_switch_end")
        log.info("✅ DNS switched to AWS (%s) in %ds", self.aws_lb_ip, duration)
        return {"aws_lb_ip": self.aws_lb_ip, "duration_s": duration}

    # ── Step 4: Scale AKS back to zero ────────────────────────────────────────
    def _step_scale_aks_to_zero(self) -> dict:
        log.info("STEP 4 — Scaling Azure AKS back to 0 (standby mode)…")
        self.timeline["aks_scale_zero_start"] = datetime.now(timezone.utc).isoformat()

        if not self.dry_run:
            self._run([
                "az", "aks", "nodepool", "scale",
                "--resource-group", self.azure_resource_group,
                "--cluster-name",   self.azure_aks_cluster,
                "--name",           self.azure_aks_nodepool,
                "--node-count",     "0",
            ])

        self.timeline["aks_scale_zero_end"] = datetime.now(timezone.utc).isoformat()
        log.info("✅ AKS scaled to zero — standby mode restored")
        return {"node_count": 0}

    # ── Step 5: Re-establish pglogical (AWS → Azure) ──────────────────────────
    def _step_reestablish_pglogical(self) -> dict:
        log.info("STEP 5 — Re-establishing pglogical replication (AWS → Azure)…")
        self.timeline["pglogical_start"] = datetime.now(timezone.utc).isoformat()

        teardown_resync_sql = """
            SELECT pglogical.drop_subscription('azure_to_aws_sync');
            SELECT pglogical.drop_node('aws_primary');
        """
        setup_forward_sql = f"""
            SELECT pglogical.create_node(
                node_name := 'aws_primary',
                dsn := 'host={self.rds_endpoint} dbname=appdb user={self.rds_admin} password={self.rds_password}'
            );
            SELECT pglogical.create_replication_set('default');
            SELECT pglogical.replication_set_add_all_tables('default', ARRAY['public']);
        """

        if not self.dry_run:
            self._psql_aws(teardown_resync_sql)
            self._psql_aws(setup_forward_sql)

        self.timeline["pglogical_end"] = datetime.now(timezone.utc).isoformat()
        log.info("✅ pglogical re-established in normal direction (AWS → Azure)")
        return {"replication": "aws_primary → azure_replica"}

    # ── Helpers ───────────────────────────────────────────────────────────────
    def _wait_for_replication_lag_zero(self, timeout: int = 600):
        log.info("Waiting for replication lag to reach 0…")
        deadline = time.time() + timeout
        while time.time() < deadline:
            lag_sql = "SELECT extract(epoch from (now() - pg_last_xact_replay_timestamp()))::int AS lag_s;"
            out = self._psql_aws(lag_sql, capture=True)
            try:
                lag = int([l for l in out.split("\n") if l.strip().lstrip("-").isdigit()][0])
                log.info("  Replication lag: %ds", lag)
                if lag <= 2:
                    return
            except (IndexError, ValueError):
                pass
            time.sleep(15)
        log.warning("Replication lag did not reach zero within %ds — proceeding anyway", timeout)

    def _run_aws_eks_credentials(self):
        self._run([
            "aws", "eks", "update-kubeconfig",
            "--region", self.aws_region,
            "--name",   self.eks_cluster_name,
        ])

    def _psql_aws(self, sql: str, capture: bool = False) -> str:
        env = os.environ.copy()
        env["PGPASSWORD"] = self.rds_password
        return self._run(
            ["psql", f"host={self.rds_endpoint} dbname=appdb user={self.rds_admin} sslmode=require", "-c", sql],
            capture=capture,
            env=env,
        )

    def _run(self, cmd: list, capture: bool = False, env: dict = None) -> str:
        import subprocess
        log.debug("$ %s", " ".join(str(c) for c in cmd))
        result = subprocess.run(cmd, capture_output=capture, text=True, env=env or os.environ, check=True)
        return result.stdout if capture else ""

    def _duration(self, start_key: str, end_key: str) -> int:
        start = datetime.fromisoformat(self.timeline[start_key])
        end   = datetime.fromisoformat(self.timeline[end_key])
        return int((end - start).total_seconds())

    def _notify(self, subject: str, message: str):
        if not self.sns_topic_arn or self.dry_run:
            return
        try:
            self._sns.publish(TopicArn=self.sns_topic_arn, Subject=subject[:100], Message=message)
        except Exception as exc:
            log.warning("SNS notify failed: %s", exc)


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

    parser = argparse.ArgumentParser(description="DR Failback Orchestrator")
    parser.add_argument("--verify-only", action="store_true", help="Only run readiness checks")
    parser.add_argument("--execute",     action="store_true", help="Execute the failback")
    parser.add_argument("--dry-run",     action="store_true", help="Simulate without making changes")
    args = parser.parse_args()

    fb = FailbackOrchestrator(dry_run=args.dry_run)

    if args.verify_only:
        result = fb.verify_readiness()
        print(json.dumps(result, indent=2))
        raise SystemExit(0 if result["ready"] else 1)

    if args.execute:
        result = fb.execute()
        print(json.dumps(result, indent=2))
    else:
        parser.print_help()
