#!/usr/bin/env python3
"""
billing_stopper — Cloud Function (Gen 1)

Triggered by: Pub/Sub topic (billing_alerts), published by GCP Billing Budget.
Action: disables billing for the project when cost >= budget (100% threshold).

Disabling billing immediately stops all billable resource activity.
The project and its resources remain but nothing further is charged.
Re-enable billing manually from the GCP console to restore operations.

Environment variables:
    GCP_PROJECT_ID  — the project to protect (set by Terraform)
"""

import base64
import json
import os

from google.cloud import billing_v1

PROJECT_ID = os.environ.get("GCP_PROJECT_ID", "")
# Safety gate: default TRUE (safe). Deploy in dry-run, validate with a synthetic
# over-budget publish, then arm by setting DRY_RUN=false. Anything other than the
# literal "false" (case-insensitive) is treated as dry-run.
DRY_RUN = os.environ.get("DRY_RUN", "true").strip().lower() != "false"


def stop_billing(event, context):
    """Entry point — called by Cloud Functions runtime on each Pub/Sub message."""
    if not PROJECT_ID:
        print("ERROR: GCP_PROJECT_ID env var not set — cannot disable billing")
        return

    # ── Decode Pub/Sub payload ─────────────────────────────────────────────────
    try:
        raw = base64.b64decode(event["data"]).decode("utf-8")
        data = json.loads(raw)
    except Exception as e:
        print(f"ERROR: failed to decode Pub/Sub message: {e}")
        return

    cost_amount = float(data.get("costAmount", 0))
    budget_amount = float(data.get("budgetAmount", 0))
    budget_name = data.get("budgetDisplayName", "unknown")

    print(
        f"Budget alert received | budget={budget_name} "
        f"cost=${cost_amount:.4f} limit=${budget_amount:.4f}"
    )

    # ── Only act when cost has hit or exceeded the budget cap ─────────────────
    if cost_amount <= budget_amount:
        print(
            f"Cost (${cost_amount:.4f}) is within budget (${budget_amount:.4f}). "
            "No action taken."
        )
        return

    print(
        f"SHUTDOWN: cost ${cost_amount:.4f} exceeded budget ${budget_amount:.4f}. "
        f"Disabling billing for project {PROJECT_ID}."
    )

    # ── Safety gate ───────────────────────────────────────────────────────────
    # In dry-run (default) log the intent but take NO action. Arm by setting
    # the DRY_RUN env var to "false" only after validating with a synthetic publish.
    if DRY_RUN:
        print(
            f"[DRY_RUN] WOULD DISABLE billing on {PROJECT_ID} "
            "(no action taken; set DRY_RUN=false to arm)."
        )
        return

    client = billing_v1.CloudBillingClient()
    project_name = f"projects/{PROJECT_ID}"

    # ── Idempotency check — avoid redundant API call if already disabled ──────
    try:
        current = client.get_project_billing_info(name=project_name)
        if not current.billing_enabled:
            print(f"Billing is already disabled for {PROJECT_ID}. Nothing to do.")
            return
    except Exception as e:
        print(f"ERROR: could not retrieve billing info: {e}")
        raise

    # ── Disable billing: set billing_account_name to empty string ─────────────
    try:
        result = client.update_project_billing_info(
            name=project_name,
            project_billing_info=billing_v1.ProjectBillingInfo(
                billing_account_name=""
            ),
        )
        print(
            f"SUCCESS: billing disabled for project {PROJECT_ID}. "
            f"billing_enabled={result.billing_enabled}"
        )
    except Exception as e:
        print(f"ERROR: failed to disable billing: {e}")
        raise
