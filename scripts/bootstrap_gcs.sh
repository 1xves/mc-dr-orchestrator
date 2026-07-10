#!/usr/bin/env bash
###############################################################################
# bootstrap_gcs.sh — Create GCS bucket for Terraform state before first init
#
# Run ONCE before terraform init:
#   chmod +x scripts/bootstrap_gcs.sh
#   ./scripts/bootstrap_gcs.sh <GCP_PROJECT_ID> [REGION]
#
# Requirements: gcloud CLI authenticated with project owner permissions
###############################################################################

set -euo pipefail

GCP_PROJECT_ID="${1:?Usage: $0 <GCP_PROJECT_ID> [REGION]}"
REGION="${2:-us-central1}"
BUCKET_NAME="mc-dr-terraform-state-${GCP_PROJECT_ID}"

echo "==> Enabling required GCP APIs..."
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  storage.googleapis.com \
  compute.googleapis.com \
  container.googleapis.com \
  sqladmin.googleapis.com \
  servicenetworking.googleapis.com \
  pubsub.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com \
  --project="${GCP_PROJECT_ID}"

echo "==> Creating GCS bucket: gs://${BUCKET_NAME}"
if gcloud storage buckets describe "gs://${BUCKET_NAME}" --project="${GCP_PROJECT_ID}" &>/dev/null; then
  echo "    Bucket already exists — skipping creation"
else
  gcloud storage buckets create "gs://${BUCKET_NAME}" \
    --project="${GCP_PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access \
    --public-access-prevention

  gcloud storage buckets update "gs://${BUCKET_NAME}" \
    --versioning

  echo "    Bucket created with versioning enabled"
fi

echo ""
echo "==> Done. Now run:"
echo ""
echo "    cd terraform"
echo "    terraform init -backend-config=\"bucket=${BUCKET_NAME}\""
echo ""
echo "    Then add to terraform.tfvars:"
echo "    gcp_project_id = \"${GCP_PROJECT_ID}\""
echo "    gcp_state_bucket = \"${BUCKET_NAME}\""
