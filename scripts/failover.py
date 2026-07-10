#!/usr/bin/env python3
"""
failover.py — GCP-primary to Azure-standby failover orchestrator

Sequence:
  1. Verify GKE primary is actually down (re-checks before acting)
  2. Scale AKS standby nodes up (0 → desired_count)
  3. Wait for AKS node pool to be ready
  4. Update Cloud DNS record to point at Azure AKS ingress
  5. Publish failover event to Pub/Sub
  6. Emit Cloud Monitoring metric

Usage:
    python scripts/failover.py --gcp-project my-project-id \
        --dns-zone mc-dr-zone --dns-name api.yourdomain.com \
        --azure-rg mc-dr-standby-rg --aks-cluster mc-dr-aks \
        --aks-ingress-ip 1.2.3.4

Environment variables (alternative to flags):
    GCP_PROJECT_ID, DNS_ZONE_NAME, DNS_RECORD_NAME,
    AZURE_RESOURCE_GROUP, AKS_CLUSTER_NAME, AKS_INGRESS_IP,
    AKS_NODE_COUNT, PUBSUB_TOPIC_ID, PRIMARY_URL
"""

import argparse
import logging
import os
import sys
import time
from datetime import datetime, timezone

import requests
from azure.identity import DefaultAzureCredential
from azure.mgmt.containerservice import ContainerServiceClient
from dotenv import load_dotenv
from google.cloud import dns, monitoring_v3, pubsub_v1

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("failover")

HEALTH_CHECK_RETRIES = 3
HEALTH_CHECK_INTERVAL = 10   # seconds between re-checks before committing to failover
AKS_READY_TIMEOUT = 600      # 10 min max wait for AKS nodes to register
AKS_READY_POLL = 20


class FailoverOrchestrator:
    def __init__(self, args):
        self.project_id = args.gcp_project
        self.dns_zone = args.dns_zone
        self.dns_name = args.dns_name.rstrip(".") + "."
        self.azure_rg = args.azure_rg
        self.aks_cluster = args.aks_cluster
        self.aks_ingress_ip = args.aks_ingress_ip
        self.aks_node_count = args.aks_node_count
        self.primary_url = args.primary_url
        self.topic_id = args.pubsub_topic
        self.dry_run = args.dry_run

        self.azure_subscription_id = os.getenv("AZURE_SUBSCRIPTION_ID", "")

        # GCP clients
        self.publisher = pubsub_v1.PublisherClient()
        self.topic_path = self.publisher.topic_path(self.project_id, self.topic_id)
        self.dns_client = dns.Client(project=self.project_id)
        self.metric_client = monitoring_v3.MetricServiceClient()
        self.project_name = f"projects/{self.project_id}"

        # Azure client
        credential = DefaultAzureCredential()
        self.aks_client = ContainerServiceClient(credential, self.azure_subscription_id)

        self.http = requests.Session()
        self.http.headers.update({"User-Agent": "DR-Failover/2.0"})

    # ── Step 1: Verify primary is actually down ──────────────────────────────
    def verify_primary_down(self) -> bool:
        log.info("Verifying primary is down (%d checks)...", HEALTH_CHECK_RETRIES)
        failures = 0
        for attempt in range(1, HEALTH_CHECK_RETRIES + 1):
            try:
                r = self.http.get(self.primary_url, timeout=10)
                if r.status_code == 200:
                    log.warning(
                        "Check %d/%d: primary responded 200 — aborting failover",
                        attempt, HEALTH_CHECK_RETRIES,
                    )
                    return False
                log.info("Check %d/%d: non-200 (%d)", attempt, HEALTH_CHECK_RETRIES, r.status_code)
                failures += 1
            except Exception as e:
                log.info("Check %d/%d: unreachable (%s)", attempt, HEALTH_CHECK_RETRIES, e)
                failures += 1

            if attempt < HEALTH_CHECK_RETRIES:
                time.sleep(HEALTH_CHECK_INTERVAL)

        log.info("Primary confirmed down (%d/%d checks failed)", failures, HEALTH_CHECK_RETRIES)
        return failures >= HEALTH_CHECK_RETRIES

    # ── Step 2: Scale AKS nodes up ──────────────────────────────────────────
    def scale_aks_up(self):
        log.info("Scaling AKS '%s' node pool to %d nodes...", self.aks_cluster, self.aks_node_count)
        if self.dry_run:
            log.info("[DRY RUN] Would scale AKS node pool to %d", self.aks_node_count)
            return

        # Get current agent pool config
        cluster = self.aks_client.managed_clusters.get(self.azure_rg, self.aks_cluster)
        agent_pool = cluster.agent_pool_profiles[0]
        agent_pool.count = self.aks_node_count
        agent_pool.min_count = 1
        agent_pool.max_count = max(3, self.aks_node_count)

        poller = self.aks_client.managed_clusters.begin_create_or_update(
            self.azure_rg, self.aks_cluster, cluster
        )
        log.info("AKS scale operation started — waiting for nodes to be ready...")

    # ── Step 3: Wait for AKS to be ready ────────────────────────────────────
    def wait_for_aks(self):
        if self.dry_run:
            log.info("[DRY RUN] Would wait for AKS nodes")
            return

        log.info("Waiting up to %ds for AKS cluster to be ready...", AKS_READY_TIMEOUT)
        deadline = time.time() + AKS_READY_TIMEOUT
        while time.time() < deadline:
            cluster = self.aks_client.managed_clusters.get(self.azure_rg, self.aks_cluster)
            state = cluster.provisioning_state
            power = cluster.power_state.code if cluster.power_state else "Unknown"
            log.info("AKS state: %s / power: %s", state, power)

            if state == "Succeeded" and power == "Running":
                log.info("AKS cluster is ready")
                return

            time.sleep(AKS_READY_POLL)

        raise TimeoutError(f"AKS cluster not ready after {AKS_READY_TIMEOUT}s")

    # ── Step 4: Update Cloud DNS ─────────────────────────────────────────────
    def update_dns(self):
        log.info(
            "Updating Cloud DNS zone '%s': %s → %s",
            self.dns_zone, self.dns_name, self.aks_ingress_ip,
        )
        if self.dry_run:
            log.info("[DRY RUN] Would update DNS record")
            return

        zone = self.dns_client.zone_from_name(self.dns_zone)

        # Find and remove existing A record
        changes = zone.changes()
        records = list(zone.list_resource_record_sets())
        for record in records:
            if record.name == self.dns_name and record.record_type == "A":
                changes.delete_record_set(record)
                log.info("Removing old A record: %s → %s", record.name, record.rrdatas)
                break

        # Add new A record pointing at AKS ingress
        new_record = zone.resource_record_set(self.dns_name, "A", 60, [self.aks_ingress_ip])
        changes.add_record_set(new_record)
        changes.create()
        log.info("DNS updated: %s → %s (TTL 60s)", self.dns_name, self.aks_ingress_ip)

    # ── Step 5: Publish Pub/Sub event ────────────────────────────────────────
    def publish_event(self, success: bool, detail: str = ""):
        status = "SUCCESS" if success else "FAILED"
        message = (
            f"DR Failover {status}\n"
            f"Time: {datetime.now(timezone.utc).isoformat()}\n"
            f"From: GKE primary ({self.primary_url})\n"
            f"To: AKS standby ({self.aks_ingress_ip})\n"
            f"DNS: {self.dns_name} updated\n"
        )
        if detail:
            message += f"Detail: {detail}\n"

        if self.dry_run:
            log.info("[DRY RUN] Would publish: %s", message.strip())
            return

        try:
            future = self.publisher.publish(
                self.topic_path,
                message.encode("utf-8"),
                event_type="failover",
                status=status,
            )
            future.result(timeout=10)
            log.info("Failover event published to Pub/Sub")
        except Exception as e:
            log.error("Pub/Sub publish failed: %s", e)

    # ── Step 6: Emit metric ───────────────────────────────────────────────────
    def emit_metric(self, metric_name: str, value: float):
        try:
            series = monitoring_v3.TimeSeries()
            series.metric.type = f"custom.googleapis.com/dr/{metric_name}"
            series.resource.type = "global"
            now = time.time()
            interval = monitoring_v3.TimeInterval(
                {"end_time": {"seconds": int(now), "nanos": 0}}
            )
            point = monitoring_v3.Point(
                {"interval": interval, "value": {"double_value": value}}
            )
            series.points = [point]
            self.metric_client.create_time_series(
                name=self.project_name, time_series=[series]
            )
        except Exception as e:
            log.debug("Metric emit failed: %s", e)

    # ── Orchestrate ───────────────────────────────────────────────────────────
    def run(self):
        log.info("=== DR Failover initiated: GKE → AKS ===")
        if self.dry_run:
            log.warning("DRY RUN — no changes will be made")

        start = time.time()

        try:
            # 1. Verify primary is actually down
            if not self.verify_primary_down():
                log.info("Primary is healthy — failover aborted. No action taken.")
                sys.exit(0)

            # 2. Scale AKS up
            self.scale_aks_up()

            # 3. Wait for AKS ready
            self.wait_for_aks()

            # 4. Flip DNS
            self.update_dns()

            elapsed = time.time() - start
            log.info("=== Failover complete in %.0fs ===", elapsed)

            # 5. Notify
            self.publish_event(success=True)
            self.emit_metric("FailoverCompleted", 1)
            self.emit_metric("FailoverDurationSeconds", elapsed)

        except Exception as e:
            log.error("Failover FAILED: %s", e, exc_info=True)
            self.publish_event(success=False, detail=str(e))
            self.emit_metric("FailoverCompleted", 0)
            sys.exit(1)

        finally:
            self.http.close()


def parse_args():
    p = argparse.ArgumentParser(description="DR Failover — GKE primary to AKS standby")
    p.add_argument("--gcp-project",    default=os.getenv("GCP_PROJECT_ID", ""))
    p.add_argument("--dns-zone",       default=os.getenv("DNS_ZONE_NAME", ""))
    p.add_argument("--dns-name",       default=os.getenv("DNS_RECORD_NAME", "api.example.com"))
    p.add_argument("--azure-rg",       default=os.getenv("AZURE_RESOURCE_GROUP", "mc-dr-standby-rg"))
    p.add_argument("--aks-cluster",    default=os.getenv("AKS_CLUSTER_NAME", "mc-dr-aks"))
    p.add_argument("--aks-ingress-ip", default=os.getenv("AKS_INGRESS_IP", ""))
    p.add_argument("--aks-node-count", type=int, default=int(os.getenv("AKS_NODE_COUNT", "2")))
    p.add_argument("--primary-url",    default=os.getenv("PRIMARY_URL", "https://api.example.com/healthz"))
    p.add_argument("--pubsub-topic",   default=os.getenv("PUBSUB_TOPIC_ID", "mc-dr-dr-alerts"))
    p.add_argument("--dry-run",        action="store_true", help="Log actions without making changes")
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()
    for field, name in [
        (args.gcp_project, "--gcp-project / GCP_PROJECT_ID"),
        (args.dns_zone, "--dns-zone / DNS_ZONE_NAME"),
        (args.aks_ingress_ip, "--aks-ingress-ip / AKS_INGRESS_IP"),
    ]:
        if not field:
            print(f"ERROR: {name} is required", file=sys.stderr)
            sys.exit(1)

    FailoverOrchestrator(args).run()
