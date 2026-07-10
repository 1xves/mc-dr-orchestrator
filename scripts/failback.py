#!/usr/bin/env python3
"""
failback.py — Azure-standby to GCP-primary failback orchestrator

Sequence (reverse of failover):
  1. Verify GKE primary is healthy (re-checks before acting)
  2. Update Cloud DNS record back to GKE ingress IP
  3. Verify traffic is serving correctly via GKE
  4. Scale AKS standby back to 0 nodes
  5. Publish failback event to Pub/Sub
  6. Emit Cloud Monitoring metric

Usage:
    python scripts/failback.py --gcp-project my-project-id \
        --dns-zone mc-dr-zone --dns-name api.yourdomain.com \
        --gke-ingress-ip 34.1.2.3 \
        --azure-rg mc-dr-standby-rg --aks-cluster mc-dr-aks

Environment variables (alternative to flags):
    GCP_PROJECT_ID, DNS_ZONE_NAME, DNS_RECORD_NAME,
    GKE_INGRESS_IP, AZURE_RESOURCE_GROUP, AKS_CLUSTER_NAME,
    PUBSUB_TOPIC_ID, PRIMARY_URL
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
log = logging.getLogger("failback")

HEALTH_CHECK_RETRIES = 5         # more checks before failback than failover
HEALTH_CHECK_INTERVAL = 10
POST_DNS_VERIFY_RETRIES = 3      # verify GKE is serving after DNS flip
POST_DNS_VERIFY_INTERVAL = 15
AKS_SCALE_TIMEOUT = 300          # 5 min wait for AKS scale-down to register
AKS_SCALE_POLL = 20


class FailbackOrchestrator:
    def __init__(self, args):
        self.project_id = args.gcp_project
        self.dns_zone = args.dns_zone
        self.dns_name = args.dns_name.rstrip(".") + "."
        self.gke_ingress_ip = args.gke_ingress_ip
        self.azure_rg = args.azure_rg
        self.aks_cluster = args.aks_cluster
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
        self.http.headers.update({"User-Agent": "DR-Failback/2.0"})

    # ── Step 1: Verify GKE is stable and healthy ─────────────────────────────
    def verify_primary_healthy(self) -> bool:
        """
        Require consecutive successes (not just one) to avoid flapping.
        All HEALTH_CHECK_RETRIES checks must pass.
        """
        log.info(
            "Verifying GKE primary is stable (%d consecutive checks required)...",
            HEALTH_CHECK_RETRIES,
        )
        for attempt in range(1, HEALTH_CHECK_RETRIES + 1):
            try:
                r = self.http.get(self.primary_url, timeout=10)
                if r.status_code != 200:
                    log.warning(
                        "Check %d/%d: non-200 (%d) — primary not stable yet",
                        attempt, HEALTH_CHECK_RETRIES, r.status_code,
                    )
                    return False
                log.info(
                    "Check %d/%d: healthy (%dms)",
                    attempt, HEALTH_CHECK_RETRIES,
                    int(r.elapsed.total_seconds() * 1000),
                )
            except Exception as e:
                log.warning("Check %d/%d: unreachable (%s)", attempt, HEALTH_CHECK_RETRIES, e)
                return False

            if attempt < HEALTH_CHECK_RETRIES:
                time.sleep(HEALTH_CHECK_INTERVAL)

        log.info("GKE primary confirmed stable — %d/%d checks passed", HEALTH_CHECK_RETRIES, HEALTH_CHECK_RETRIES)
        return True

    # ── Step 2: Flip DNS back to GKE ─────────────────────────────────────────
    def update_dns(self):
        log.info(
            "Updating Cloud DNS zone '%s': %s → %s (back to GKE)",
            self.dns_zone, self.dns_name, self.gke_ingress_ip,
        )
        if self.dry_run:
            log.info("[DRY RUN] Would update DNS record back to GKE IP")
            return

        zone = self.dns_client.zone_from_name(self.dns_zone)
        changes = zone.changes()

        records = list(zone.list_resource_record_sets())
        for record in records:
            if record.name == self.dns_name and record.record_type == "A":
                changes.delete_record_set(record)
                log.info("Removing current A record: %s → %s", record.name, record.rrdatas)
                break

        new_record = zone.resource_record_set(self.dns_name, "A", 60, [self.gke_ingress_ip])
        changes.add_record_set(new_record)
        changes.create()
        log.info("DNS updated: %s → %s (TTL 60s)", self.dns_name, self.gke_ingress_ip)

    # ── Step 3: Post-DNS verification ────────────────────────────────────────
    def verify_post_dns(self) -> bool:
        """Allow TTL propagation time, then confirm the endpoint responds."""
        log.info(
            "Waiting for DNS propagation; will verify %d times with %ds gaps...",
            POST_DNS_VERIFY_RETRIES, POST_DNS_VERIFY_INTERVAL,
        )
        if self.dry_run:
            log.info("[DRY RUN] Would verify post-DNS health")
            return True

        time.sleep(30)  # brief propagation grace period

        for attempt in range(1, POST_DNS_VERIFY_RETRIES + 1):
            try:
                r = self.http.get(self.primary_url, timeout=15)
                if r.status_code == 200:
                    log.info("Post-DNS check %d/%d: OK (%dms)", attempt, POST_DNS_VERIFY_RETRIES,
                             int(r.elapsed.total_seconds() * 1000))
                    return True
                log.warning("Post-DNS check %d/%d: non-200 (%d)", attempt, POST_DNS_VERIFY_RETRIES, r.status_code)
            except Exception as e:
                log.warning("Post-DNS check %d/%d: %s", attempt, POST_DNS_VERIFY_RETRIES, e)

            if attempt < POST_DNS_VERIFY_RETRIES:
                time.sleep(POST_DNS_VERIFY_INTERVAL)

        log.error("Post-DNS verification failed — GKE may not be serving traffic yet")
        return False

    # ── Step 4: Scale AKS to 0 ───────────────────────────────────────────────
    def scale_aks_down(self):
        log.info("Scaling AKS '%s' node pool to 0 (standby mode)...", self.aks_cluster)
        if self.dry_run:
            log.info("[DRY RUN] Would scale AKS to 0")
            return

        cluster = self.aks_client.managed_clusters.get(self.azure_rg, self.aks_cluster)
        agent_pool = cluster.agent_pool_profiles[0]
        agent_pool.count = 0
        agent_pool.min_count = 0
        agent_pool.max_count = 3  # keep autoscaler ceiling; min=0 enables scale-to-zero

        self.aks_client.managed_clusters.begin_create_or_update(
            self.azure_rg, self.aks_cluster, cluster
        )
        log.info("AKS scale-to-zero initiated — cluster will idle with PVC persisted")

        # Best-effort wait (non-blocking failure — nodes take time to drain)
        deadline = time.time() + AKS_SCALE_TIMEOUT
        while time.time() < deadline:
            cluster = self.aks_client.managed_clusters.get(self.azure_rg, self.aks_cluster)
            if cluster.provisioning_state == "Succeeded":
                log.info("AKS scale-down complete")
                return
            log.info("AKS provisioning state: %s", cluster.provisioning_state)
            time.sleep(AKS_SCALE_POLL)

        log.warning(
            "AKS did not confirm scale-down within %ds — cluster will finish in background",
            AKS_SCALE_TIMEOUT,
        )

    # ── Step 5: Publish Pub/Sub event ────────────────────────────────────────
    def publish_event(self, success: bool, detail: str = ""):
        status = "SUCCESS" if success else "FAILED"
        message = (
            f"DR Failback {status}\n"
            f"Time: {datetime.now(timezone.utc).isoformat()}\n"
            f"To: GKE primary ({self.gke_ingress_ip})\n"
            f"AKS standby: scaled to 0 (PVC retained)\n"
            f"DNS: {self.dns_name} restored to GKE\n"
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
                event_type="failback",
                status=status,
            )
            future.result(timeout=10)
            log.info("Failback event published to Pub/Sub")
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
        log.info("=== DR Failback initiated: AKS → GKE (primary restore) ===")
        if self.dry_run:
            log.warning("DRY RUN — no changes will be made")

        start = time.time()

        try:
            # 1. Confirm GKE is stable before cutting traffic back
            if not self.verify_primary_healthy():
                log.error(
                    "GKE primary is NOT stable — failback aborted. "
                    "Investigate cluster health before retrying."
                )
                self.emit_metric("FailbackCompleted", 0)
                sys.exit(1)

            # 2. Flip DNS back to GKE
            self.update_dns()

            # 3. Verify GKE is serving traffic post-DNS flip
            if not self.verify_post_dns():
                log.error(
                    "Post-DNS verification failed. "
                    "DNS has been flipped but GKE endpoint is not responding. "
                    "Consider re-running failover.py to restore service on AKS."
                )
                self.publish_event(success=False, detail="Post-DNS health check failed")
                self.emit_metric("FailbackCompleted", 0)
                sys.exit(1)

            # 4. Scale AKS to 0 — PVC is retained, data preserved
            self.scale_aks_down()

            elapsed = time.time() - start
            log.info("=== Failback complete in %.0fs ===", elapsed)

            # 5. Notify
            self.publish_event(success=True)
            self.emit_metric("FailbackCompleted", 1)
            self.emit_metric("FailbackDurationSeconds", elapsed)

        except Exception as e:
            log.error("Failback FAILED: %s", e, exc_info=True)
            self.publish_event(success=False, detail=str(e))
            self.emit_metric("FailbackCompleted", 0)
            sys.exit(1)

        finally:
            self.http.close()


def parse_args():
    p = argparse.ArgumentParser(description="DR Failback — AKS standby back to GKE primary")
    p.add_argument("--gcp-project",    default=os.getenv("GCP_PROJECT_ID", ""))
    p.add_argument("--dns-zone",       default=os.getenv("DNS_ZONE_NAME", ""))
    p.add_argument("--dns-name",       default=os.getenv("DNS_RECORD_NAME", "api.example.com"))
    p.add_argument("--gke-ingress-ip", default=os.getenv("GKE_INGRESS_IP", ""))
    p.add_argument("--azure-rg",       default=os.getenv("AZURE_RESOURCE_GROUP", "mc-dr-standby-rg"))
    p.add_argument("--aks-cluster",    default=os.getenv("AKS_CLUSTER_NAME", "mc-dr-aks"))
    p.add_argument("--primary-url",    default=os.getenv("PRIMARY_URL", "https://api.example.com/healthz"))
    p.add_argument("--pubsub-topic",   default=os.getenv("PUBSUB_TOPIC_ID", "mc-dr-dr-alerts"))
    p.add_argument("--dry-run",        action="store_true", help="Log actions without making changes")
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()
    for field, name in [
        (args.gcp_project, "--gcp-project / GCP_PROJECT_ID"),
        (args.dns_zone, "--dns-zone / DNS_ZONE_NAME"),
        (args.gke_ingress_ip, "--gke-ingress-ip / GKE_INGRESS_IP"),
    ]:
        if not field:
            print(f"ERROR: {name} is required", file=sys.stderr)
            sys.exit(1)

    FailbackOrchestrator(args).run()
