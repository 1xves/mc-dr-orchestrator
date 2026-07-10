###############################################################################
# billing_stopper.tf
#
# Hard-cap enforcement: when the monthly GCP budget is exceeded, a Cloud
# Function automatically disables billing for the project — stopping all
# further charges immediately.
#
# Chain:
#   Billing Budget (100% alert)
#     → Pub/Sub topic (billing_alerts)
#       → Cloud Function (billing_stopper)
#         → billing_v1.update_project_billing_info(billing_account_name="")
#
# All resources are gated on var.gcp_billing_account_id being non-empty.
# If no billing account ID is set, the entire block is a no-op.
###############################################################################

# ── Dedicated Pub/Sub topic for billing alerts ────────────────────────────────
# Kept separate from the DR-ops topic so billing shutdown events are not mixed
# with failover/failback notifications.
resource "google_pubsub_topic" "billing_alerts" {
  count   = var.gcp_billing_account_id != "" ? 1 : 0
  name    = "${var.project_name}-billing-alerts"
  project = var.gcp_project_id
  labels  = local.common_labels
}

# ── Service account for the Cloud Function ────────────────────────────────────
resource "google_service_account" "billing_stopper" {
  count        = var.gcp_billing_account_id != "" ? 1 : 0
  account_id   = "billing-stopper"
  display_name = "Billing Auto-Stopper"
  description  = "Disables project billing when the monthly budget cap is exceeded"
  project      = var.gcp_project_id
}

# ── Grant billing.admin on the billing account ────────────────────────────────
# billing.admin includes billing.resourceAssociations.delete which is required
# to call update_project_billing_info with an empty billing account name.
resource "google_billing_account_iam_member" "billing_stopper_admin" {
  count              = var.gcp_billing_account_id != "" ? 1 : 0
  billing_account_id = var.gcp_billing_account_id
  role               = "roles/billing.admin"
  member             = "serviceAccount:${google_service_account.billing_stopper[0].email}"
}

# ── GCS bucket for function source archives ───────────────────────────────────
resource "google_storage_bucket" "function_source" {
  count                       = var.gcp_billing_account_id != "" ? 1 : 0
  name                        = "${var.gcp_project_id}-functions-src"
  location                    = var.gcp_region
  project                     = var.gcp_project_id
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = local.common_labels

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 30 } # auto-clean old deployment zips
  }
}

# ── Zip the function source directory ─────────────────────────────────────────
# Re-zipped on every `terraform plan` if source files change (via output_md5).
data "archive_file" "billing_stopper" {
  type        = "zip"
  source_dir  = "${path.root}/../functions/billing_stopper"
  output_path = "${path.root}/../functions/billing_stopper.zip"
}

resource "google_storage_bucket_object" "billing_stopper_zip" {
  count = var.gcp_billing_account_id != "" ? 1 : 0
  # md5 in name forces a new object (and function redeploy) when code changes
  name   = "billing_stopper_${data.archive_file.billing_stopper.output_md5}.zip"
  bucket = google_storage_bucket.function_source[0].name
  source = data.archive_file.billing_stopper.output_path
}

# ── Cloud Function (Gen 1) ────────────────────────────────────────────────────
resource "google_cloudfunctions_function" "billing_stopper" {
  count       = var.gcp_billing_account_id != "" ? 1 : 0
  name        = "${var.project_name}-billing-stopper"
  description = "Disables project billing when the monthly budget is exceeded"
  runtime     = "python311"
  region      = var.gcp_region
  project     = var.gcp_project_id

  available_memory_mb   = 128
  timeout               = 60
  source_archive_bucket = google_storage_bucket.function_source[0].name
  source_archive_object = google_storage_bucket_object.billing_stopper_zip[0].name
  entry_point           = "stop_billing"
  service_account_email = google_service_account.billing_stopper[0].email

  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.billing_alerts[0].name

    # Do not retry — billing disable is idempotent but a retry loop
    # after a transient error could fire against an already-disabled project.
    failure_policy {
      retry = false
    }
  }

  environment_variables = {
    GCP_PROJECT_ID = var.gcp_project_id
    # Safety: deploy in dry-run. Arm later by setting this to "false" and re-applying.
    DRY_RUN = "true"
  }

  labels = local.common_labels

  depends_on = [google_project_service.apis]
}
