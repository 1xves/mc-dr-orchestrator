#!/usr/bin/env python3
"""
health_monitor.py — Primary health checker

Polls the primary endpoint every CHECK_INTERVAL seconds.
On FAILURE_THRESHOLD consecutive failures → sends SNS alert.

Usage:
    python health_monitor.py --primary-url https://api.primary.com/healthz

Environment variables:
    PRIMARY_URL, CHECK_INTERVAL, FAILURE_THRESHOLD,
    SNS_TOPIC_ARN, AWS_REGION, SLACK_WEBHOOK_URL
"""

import argparse
import logging
import os
import sys
import time
from datetime import datetime, timezone
from typing import Optional

import boto3
import requests
from dotenv import load_dotenv

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

        region = os.getenv("AWS_REGION", "us-east-1")
        self.sns_topic_arn = os.getenv("SNS_TOPIC_ARN", "")
        self.sns = boto3.client("sns", region_name=region)
        self.cloudwatch = boto3.client("cloudwatch", region_name=region)

        # Persistent HTTP session — reuses connections, no port leak
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": "DR-HealthMonitor/1.0"})

        log.info("HealthMonitor started | url=%s interval=%ss threshold=%d",
                 primary_url, check_interval, failure_threshold)

    def check_health(self) -> bool:
        try:
            r = self.session.get(self.primary_url, timeout=self.timeout)
            if r.status_code == 200:
                latency_ms = r.elapsed.total_seconds() * 1000
                log.info("✅ Healthy | status=%d latency=%.0fms", r.status_code, latency_ms)
                self._emit("PrimaryLatency", latency_ms, "Milliseconds")
                self._emit("PrimaryHealthy", 1, "Count")
                return True
            log.warning("⚠️  Non-200 response | status=%d", r.status_code)
        except requests.exceptions.Timeout:
            log.warning("⚠️  Timed out after %ds", self.timeout)
        except requests.exceptions.ConnectionError as e:
            log.warning("⚠️  Connection error: %s", e)
        except Exception as e:
            log.error("❌ Unexpected error: %s", e, exc_info=True)

        self._emit("PrimaryHealthy", 0, "Count")
        return False

    def run(self):
        log.info("Starting monitor loop…")
        try:
            while True:
                self.total_checks += 1
                healthy = self.check_health()

                if healthy:
                    self.consecutive_failures = 0
                    self.last_success = datetime.now(timezone.utc)
                    self._emit("ConsecutiveFailures", 0, "Count")
                else:
                    self.consecutive_failures += 1
                    self._emit("ConsecutiveFailures", self.consecutive_failures, "Count")
                    log.warning("Failure %d/%d", self.consecutive_failures, self.failure_threshold)

                    if self.consecutive_failures >= self.failure_threshold:
                        self._alert()

                time.sleep(self.check_interval)
        finally:
            self.session.close()

    def _alert(self):
        subject = "[DR] 🚨 Primary endpoint unreachable"
        message = (
            f"Endpoint: {self.primary_url}\n"
            f"Consecutive failures: {self.consecutive_failures}\n"
            f"Last success: {self.last_success}\n"
            f"Time: {datetime.now(timezone.utc).isoformat()}\n\n"
            "Manual intervention required — check EKS cluster and RDS health."
        )
        log.critical("ALERT: %s", subject)
        if self.sns_topic_arn:
            try:
                self.sns.publish(TopicArn=self.sns_topic_arn,
                                 Subject=subject[:100], Message=message)
                log.info("SNS alert sent")
            except Exception as e:
                log.error("SNS publish failed: %s", e)

    def _emit(self, name: str, value: float, unit: str):
        try:
            self.cloudwatch.put_metric_data(
                Namespace="DR/HealthMonitor",
                MetricData=[{
                    "MetricName": name,
                    "Value": value,
                    "Unit": unit,
                    "Timestamp": datetime.now(timezone.utc),
                    "Dimensions": [{"Name": "PrimaryURL", "Value": self.primary_url}],
                }],
            )
        except Exception as e:
            log.debug("CloudWatch metric failed: %s", e)


def parse_args():
    p = argparse.ArgumentParser(description="DR Health Monitor")
    p.add_argument("--primary-url",
                   default=os.getenv("PRIMARY_URL", "https://api.primary.com/healthz"))
    p.add_argument("--check-interval", type=int,
                   default=int(os.getenv("CHECK_INTERVAL", "30")))
    p.add_argument("--failure-threshold", type=int,
                   default=int(os.getenv("FAILURE_THRESHOLD", "3")))
    p.add_argument("--timeout", type=int,
                   default=int(os.getenv("CHECK_TIMEOUT", "10")))
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
