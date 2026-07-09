#!/usr/bin/env python3
"""
failover.py — Automated failover orchestrator

Executes the full DR failover sequence:
  1. Scale Azure AKS app node pool from 0 → N nodes
  2. Wait for nodes to become Ready
  3. Deploy application workloads to AKS
  4. Promote Azure PostgreSQL replica (break pglogical replication + open for writes)
  5. Update Route53 DNS to point to Azure load balancer
  6. Emit metrics and send notifications

Can also be run standalone:
    python failover.py --mode full
    python failover.py --mode db-only
    python failover.py --mode app-only
"""

import json
import logging
import os
import subprocess
import time
from datetime import datetime, timezone
from enum import Enum

import boto3
from azure.identity import DefaultAzureCredential
from azure.mgmt.containerservice import ContainerServiceClient
from dotenv import load_dotenv

load_dotenv()
log = logging.getLogger("failover")


class FailoverMode(Enum):
    FULL    = "full"
    DB_ONLY = "db-only"
    APP_ONLY = "app-only"


class FailoverOrchestrator:
    def __init__(self):
        # Azure config
        self.azure_subscription_id  = os.environ["AZURE_SUBSCRIPTION_ID"]
        self.azure_resource_group   = os.environ["AZURE_RESOURCE_GROUP"]
        self.azure_aks_cluster      = os.environ["AZURE_AKS_CLUSTER"]
        self.azure_aks_nodepool     = os.environ.get("AZURE_AKS_NODEPOOL", "app")
        self.aks_failover_node_count = int(os.environ.get("AKS_FAILOVER_NODE_COUNT", "3"))
        self.azure_pg_fqdn          = os.environ["AZURE_PG_FQDN"]
        self.azure_pg_admin         = os.environ.get("AZURE_PG_ADMIN", "dbadmin")
        self.azure_pg_password      = os.environ.get("AZURE_PG_PASSWORD", "")

        # AWS config
        self.aws_region             = os.environ.get("AWS_REGION", "us-east-1")
        self.route53_zone_id        = os.environ["ROUTE53_ZONE_ID"]
        self.dns_record_name        = os.environ.get("DNS_RECORD_NAME", "api.example.com")
        self.azure_lb_ip            = os.environ.get("AZURE_LB_IP", "")
        self.sns_topic_arn          = os.environ.get("SNS_TOPIC_ARN", "")

        # Kubernetes manifests path
        self.k8s_manifests_path     = os.environ.get("K8S_MANIFESTS_PATH", "../k8s/azure")

        # Azure SDK clients
        self._credential = DefaultAzureCredential()
        self._aks_client = ContainerServiceClient(self._credential, self.azure_subscription_id)

        # AWS clients
        self._route53 = boto3.client("route53")
        self._cloudwatch = boto3.client("cloudwatch", region_name=self.aws_region)
        self._sns = boto3.client("sns", region_name=self.aws_region)

        self.timeline: dict = {}

    # ── Public entry point ────────────────────────────────────────────────────
    def execute(self, mode: FailoverMode = FailoverMode.FULL) -> dict:
        self.timeline["failover_start"] = datetime.now(timezone.utc).isoformat()
        log.info("=== FAILOVER STARTED | mode=%s ===", mode.value)

        result = {"mode": mode.value, "steps": {}, "success": False}

        try:
            if mode in (FailoverMode.FULL, FailoverMode.APP_ONLY):
                result["steps"]["aks_scale"]   = self._step_scale_aks()
                result["steps"]["aks_deploy"]  = self._step_deploy_to_aks()

            if mode in (FailoverMode.FULL, FailoverMode.DB_ONLY):
                result["steps"]["db_promote"]  = self._step_promote_db()

            if mode == FailoverMode.FULL:
                result["steps"]["dns_update"]  = self._step_update_dns()

            self.timeline["failover_end"] = datetime.now(timezone.utc).isoformat()
            result["timeline"] = self.timeline
            result["success"] = True

            log.info("=== FAILOVER COMPLETED SUCCESSFULLY ===")
            self._emit_metric("FailoverSuccess", 1)
            return result

        except Exception as exc:
            log.error("Failover failed at step: %s", exc, exc_info=True)
            self._emit_metric("FailoverSuccess", 0)
            result["error"] = str(exc)
            result["timeline"] = self.timeline
            raise

    # ── Step 1: Scale AKS nodes ───────────────────────────────────────────────
    def _step_scale_aks(self) -> dict:
        log.info("STEP 1 — Scaling AKS node pool '%s' to %d nodes…",
                 self.azure_aks_nodepool, self.aks_failover_node_count)
        self.timeline["aks_scale_start"] = datetime.now(timezone.utc).isoformat()

        cmd = [
            "az", "aks", "nodepool", "scale",
            "--resource-group", self.azure_resource_group,
            "--cluster-name",   self.azure_aks_cluster,
            "--name",           self.azure_aks_nodepool,
            "--node-count",     str(self.aks_failover_node_count),
            "--no-wait",
        ]
        self._run(cmd)

        # Wait for nodes to be Ready (poll every 30s, timeout 10min)
        log.info("Waiting for AKS nodes to become Ready…")
        self._get_aks_credentials()

        deadline = time.time() + 600  # 10 min
        while time.time() < deadline:
            ready = self._count_ready_nodes()
            log.info("  AKS ready nodes: %d / %d", ready, self.aks_failover_node_count)
            if ready >= self.aks_failover_node_count:
                break
            time.sleep(30)
        else:
            raise TimeoutError("AKS nodes did not become Ready within 10 minutes")

        self.timeline["aks_scale_end"] = datetime.now(timezone.utc).isoformat()
        duration = self._duration("aks_scale_start", "aks_scale_end")
        log.info("✅ AKS scaled in %ds", duration)
        return {"nodes_ready": self.aks_failover_node_count, "duration_s": duration}

    # ── Step 2: Deploy workloads to AKS ──────────────────────────────────────
    def _step_deploy_to_aks(self) -> dict:
        log.info("STEP 2 — Deploying application manifests to AKS…")
        self.timeline["aks_deploy_start"] = datetime.now(timezone.utc).isoformat()

        self._run(["kubectl", "apply", "-f", self.k8s_manifests_path, "--recursive"])
        self._run(["kubectl", "rollout", "status", "deployment", "-n", "app", "--timeout=300s"])

        self.timeline["aks_deploy_end"] = datetime.now(timezone.utc).isoformat()
        duration = self._duration("aks_deploy_start", "aks_deploy_end")
        log.info("✅ Workloads deployed in %ds", duration)
        return {"manifests_path": self.k8s_manifests_path, "duration_s": duration}

    # ── Step 3: Promote Azure PostgreSQL ─────────────────────────────────────
    def _step_promote_db(self) -> dict:
        log.info("STEP 3 — Promoting Azure PostgreSQL replica…")
        self.timeline["db_promote_start"] = datetime.now(timezone.utc).isoformat()

        # Record last LSN before severing replication (used for RPO calculation)
        last_lsn = self._get_last_lsn()
        log.info("  Last replicated LSN before promotion: %s", last_lsn)

        # Drop pglogical subscription (makes the replica writable)
        promote_sql = """
            SELECT pglogical.drop_subscription('aws_subscription');
            SELECT pglogical.drop_node('replica_node');
        """
        self._psql(promote_sql)

        # Verify the replica accepts writes
        self._psql("CREATE TABLE IF NOT EXISTS dr_failover_marker (ts TIMESTAMPTZ DEFAULT now());")
        self._psql("INSERT INTO dr_failover_marker DEFAULT VALUES;")

        self.timeline["db_promote_end"] = datetime.now(timezone.utc).isoformat()
        duration = self._duration("db_promote_start", "db_promote_end")
        log.info("✅ PostgreSQL promoted in %ds", duration)
        return {"last_lsn": last_lsn, "duration_s": duration}

    # ── Step 4: Update Route53 DNS ────────────────────────────────────────────
    def _step_update_dns(self) -> dict:
        log.info("STEP 4 — Updating Route53 DNS to Azure…")
        self.timeline["dns_update_start"] = datetime.now(timezone.utc).isoformat()

        change_batch = {
            "Comment": f"DR failover to Azure — {datetime.now(timezone.utc).isoformat()}",
            "Changes": [{
                "Action": "UPSERT",
                "ResourceRecordSet": {
                    "Name": self.dns_record_name,
                    "Type": "A",
                    "TTL": 60,
                    "ResourceRecords": [{"Value": self.azure_lb_ip}],
                },
            }],
        }

        response = self._route53.change_resource_record_sets(
            HostedZoneId=self.route53_zone_id,
            ChangeBatch=change_batch,
        )
        change_id = response["ChangeInfo"]["Id"]
        log.info("  DNS change submitted: %s", change_id)

        # Wait for DNS change to propagate
        waiter = self._route53.get_waiter("resource_record_sets_changed")
        waiter.wait(Id=change_id)

        self.timeline["dns_update_end"] = datetime.now(timezone.utc).isoformat()
        duration = self._duration("dns_update_start", "dns_update_end")
        log.info("✅ DNS updated in %ds | now points to Azure (%s)", duration, self.azure_lb_ip)
        return {"dns_record": self.dns_record_name, "azure_ip": self.azure_lb_ip, "duration_s": duration}

    # ── Helpers ───────────────────────────────────────────────────────────────
    def _get_aks_credentials(self):
        self._run([
            "az", "aks", "get-credentials",
            "--resource-group", self.azure_resource_group,
            "--name",           self.azure_aks_cluster,
            "--overwrite-existing",
        ])

    def _count_ready_nodes(self) -> int:
        result = self._run(
            ["kubectl", "get", "nodes", "-l", "agentpool=app",
             "--no-headers", "-o", "custom-columns=STATUS:.status.conditions[-1].type"],
            capture=True,
        )
        return result.count("Ready")

    def _get_last_lsn(self) -> str:
        result = self._psql("SELECT pg_current_wal_lsn();", capture=True)
        return result.strip().split("\n")[-1].strip()

    def _psql(self, sql: str, capture: bool = False) -> str:
        env = os.environ.copy()
        env["PGPASSWORD"] = self.azure_pg_password
        cmd = [
            "psql",
            f"host={self.azure_pg_fqdn} dbname=appdb user={self.azure_pg_admin} sslmode=require",
            "-c", sql,
        ]
        return self._run(cmd, capture=capture, env=env)

    def _run(self, cmd: list, capture: bool = False, env: dict = None) -> str:
        log.debug("$ %s", " ".join(str(c) for c in cmd))
        result = subprocess.run(
            cmd,
            capture_output=capture,
            text=True,
            env=env or os.environ,
            check=True,
        )
        return result.stdout if capture else ""

    def _duration(self, start_key: str, end_key: str) -> int:
        start = datetime.fromisoformat(self.timeline[start_key])
        end   = datetime.fromisoformat(self.timeline[end_key])
        return int((end - start).total_seconds())

    def _emit_metric(self, name: str, value: float):
        try:
            self._cloudwatch.put_metric_data(
                Namespace="DR/Failover",
                MetricData=[{
                    "MetricName": name,
                    "Value": value,
                    "Unit": "Count",
                    "Timestamp": datetime.now(timezone.utc),
                }],
            )
        except Exception as exc:
            log.debug("CloudWatch emit failed: %s", exc)


# ── Standalone CLI ────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

    parser = argparse.ArgumentParser(description="DR Failover Orchestrator")
    parser.add_argument(
        "--mode",
        choices=["full", "db-only", "app-only"],
        default="full",
        help="Failover scope (default: full)",
    )
    args = parser.parse_args()

    orchestrator = FailoverOrchestrator()
    result = orchestrator.execute(FailoverMode(args.mode))
    print(json.dumps(result, indent=2))
