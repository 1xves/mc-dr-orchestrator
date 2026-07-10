#!/usr/bin/env python3
"""
health_monitor.py — Primary endpoint health checker (GCP-native)

Polls the GKE primary endpoint every CHECK_INTERVAL seconds.
On FAILURE_THRESHOLD consecutive failures:
  - Publishes alert to GCP Pub/Sub topic
  - Emits custom metric to Cloud Monitoring

Usage:
    python health_monitor.py --primary-url https://api.yourdomain.com/healthz

Environment variables:
    PRIMARY_URL, CHECK_INTERVAL, FAILURE_THRESHOLD, CHECK_TIMEOUT,
    GCP_PROJECT_ID, PUBSUB_TOPIC_ID, SLACK_WEBHOOK_URL
"""

import argparse
import logging
import os
import sys
import time
from datetime import datetime, timezone
from typing import Optional

import requests
from dotenv import load_dotenv
from google.cloud import monitoring_v3, pubsub_v1

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("health_monitor")


class HealthMonitor:
    def __init__(
        self,
        primary_url: str,
        check_interval: int = 30,
        failure_threshold: int = 3,
        timeout: int = 10,
    ):
        self.primary_url = primary_url
        self.check_interval = check_interval
        self.failure_threshold = failure_threshold
        self.timeout = timeout

        self.consecutive_failures = 0
        self.total_checks = 0
        self.last_success: Optional[datetime] = None

        self.project_id = os.getenv("GCP_PROJECT_ID", "")
        self.topic_id = os.getenv("PUBSUB_TOPIC_ID", "mc-dr-dr-alerts")
        self.slack_webhook = os.getenv("SLACK_WEBHOOK_URL", "")

        # GCP clients
        if self.project_id:
            self.publisher = pubsub_v1.PublisherClient()
            self.topic_path = self.publisher.topic_path(self.project_id, self.topic_id)
            self.metric_client = monitoring_v3.MetricServiceClient()
            self.project_name = f"projects/{self.project_id}"
        else:
            log.warning("GCP_PROJECT_ID not set — Pub/Sub and Cloud Monitoring disabled")
            self.publisher = None
            self.metric_client = None

        # Persistent HTTP session — reuses connections, no port leak
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": "DR-HealthMonitor/2.0"})

        log.info(
            "HealthMonitor started | url=%s interval=%ss threshold=%d project=%s",
            primary_url, check_interval, failure_threshold, self.project_id or "unset",
        )

    def check_health(self) -> bool:
        try:
            r = self.session.get(self.primary_url, timeout=self.timeout)
            if r.status_code == 200:
                latency_ms = r.elapsed.total_seconds() * 1000
                log.info("✅ Healthy | status=%d latency=%.0fms", r.status_code, latency_ms)
                self._emit_metric("PrimaryLatencyMs", latency_ms, "ms")
                self._emit_metric("PrimaryHealthy", 1, "1")
                return True
            log.warning("⚠️  Non-200 response | status=%d", r.status_code)
        except requests.exceptions.Timeout:
            log.warning("⚠️  Timed out after %ds", self.timeout)
        except requests.exceptions.ConnectionError as e:
            log.warning("⚠️  Connection error: %s", e)
        except Exception as e:
            log.error("❌ Unexpected error: %s", e, exc_info=True)

        self._emit_metric("PrimaryHealthy", 0, "1")
        return False

    def run(self):
        log.info("Starting monitor loop...")
        try:
            while True:
                self.total_checks += 1
                healthy = self.check_health()

                if healthy:
                    self.consecutive_failures = 0
                    self.last_success = datetime.now(timezone.utc)
                    self._emit_metric("ConsecutiveFailures", 0, "1")
                else:
                    self.consecutive_failures += 1
                    self._emit_metric("ConsecutiveFailures", self.consecutive_failures, "1")
                    log.warning(
                        "Failure %d/%d", self.consecutive_failures, self.failure_threshold
                    )
                    if self.consecutive_failures >= self.failure_threshold:
                        self._alert()

                time.sleep(self.check_interval)
        finally:
            self.session.close()
            log.info("HTTP session closed.")

    def _alert(self):
        subject = "[DR] Primary endpoint unreachable"
        message = (
            f"Endpoint: {self.primary_url}\n"
            f"Consecutive failures: {self.consecutive_failures}\n"
            f"Last success: {self.last_success}\n"
            f"Time: {datetime.now(timezone.utc).isoformat()}\n\n"
            "Manual intervention may be required — check GKE cluster and Postgres pod health.\n"
            "To initiate failover: python scripts/failover.py"
        )
        log.critical("ALERT: %s", subject)

        # Pub/Sub alert
        if self.publisher:
            try:
                data = f"{subject}\n\n{message}".encode("utf-8")
                future = self.publisher.publish(
                    self.topic_path,
                    data,
                    subject=subject,
                    source="health_monitor",
                    endpoint=self.primary_url,
                )
                future.result(timeout=10)
                log.info("Pub/Sub alert published to %s", self.topic_path)
            except Exception as e:
                log.error("Pub/Sub publish failed: %s", e)

        # Slack webhook (optional, direct HTTP — no AWS dependency)
        if self.slack_webhook:
            try:
                self.session.post(
                    self.slack_webhook,
                    json={"text": f"*{subject}*\n```{message}```"},
                    timeout=5,
                )
                log.info("Slack alert sent")
            except Exception as e:
                log.error("Slack webhook failed: %s", e)

    def _emit_metric(self, metric_name: str, value: float, unit: str):
        """Write a custom metric to Cloud Monitoring."""
        if not self.metric_client:
            return
        try:
            series = monitoring_v3.TimeSeries()
            series.metric.type = f"custom.googleapis.com/dr/{metric_name}"
            series.metric.labels["endpoint"] = self.primary_url[:64]
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
            log.debug("Cloud Monitoring metric failed: %s", e)


def parse_args():
    p = argparse.ArgumentParser(description="DR Health Monitor — GCP primary")
    p.add_argument(
        "--primary-url",
        default=os.getenv("PRIMARY_URL", "https://api.primary.example.com/healthz"),
    )
    p.add_argument(
        "--check-interval",
        type=int,
        default=int(os.getenv("CHECK_INTERVAL", "30")),
    )
    p.add_argument(
        "--failure-threshold",
        type=int,
        default=int(os.getenv("FAILURE_THRESHOLD", "3")),
    )
    p.add_argument(
        "--timeout",
        type=int,
        default=int(os.getenv("CHECK_TIMEOUT", "10")),
    )
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()
    monitor = HealthMonitor(
        primary_url=args.primary_url,
        check_interval=args.check_interval,
        failure_threshold=args.failure_threshold,
        timeout=args.timeout,
    )
    try:
        monitor.run()
    except KeyboardInterrupt:
        log.info("Stopped.")
        sys.exit(0)
