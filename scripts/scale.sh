#!/usr/bin/env bash
###############################################################################
# scale.sh — Scale GCP + Azure clusters up/down to control cost
#
# Usage:
#   ./scripts/scale.sh up       — bring both clusters to minimum working state
#   ./scripts/scale.sh down     — scale to zero (stops compute billing)
#   ./scripts/scale.sh status   — show current node counts
#
# Cost impact:
#   up:   ~$5-8/day (GKE nodes + AKS nodes + Cloud SQL + PostgreSQL Flexible)
#   down: ~$1-2/day (GKE control plane $0.10/hr + Cloud SQL storage only)
#
# Requirements: gcloud CLI and az CLI both authenticated
###############################################################################

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
GCP_PROJECT="${GCP_PROJECT_ID:-}"
GCP_REGION="us-central1"
GKE_CLUSTER="mc-dr-gke"
GKE_NODEPOOL="mc-dr-gke-app"

AZURE_RG="mc-dr-standby-rg"
AKS_CLUSTER="mc-dr-aks"

# ── Helpers ───────────────────────────────────────────────────────────────────
check_deps() {
  command -v gcloud >/dev/null 2>&1 || { echo "gcloud CLI not found"; exit 1; }
  command -v az     >/dev/null 2>&1 || { echo "az CLI not found"; exit 1; }

  if [[ -z "${GCP_PROJECT}" ]]; then
    GCP_PROJECT=$(gcloud config get-value project 2>/dev/null)
    if [[ -z "${GCP_PROJECT}" ]]; then
      echo "Set GCP_PROJECT_ID env var or run: gcloud config set project <PROJECT_ID>"
      exit 1
    fi
  fi
}

scale_gke() {
  local min_count=$1
  local max_count=$2
  echo "==> GKE: scaling nodepool '${GKE_NODEPOOL}' to min=${min_count} max=${max_count}"
  gcloud container clusters resize "${GKE_CLUSTER}" \
    --node-pool="${GKE_NODEPOOL}" \
    --num-nodes="${min_count}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT}" \
    --quiet
}

scale_aks() {
  local node_count=$1
  echo "==> AKS: scaling cluster '${AKS_CLUSTER}' to ${node_count} nodes"
  az aks scale \
    --resource-group "${AZURE_RG}" \
    --name "${AKS_CLUSTER}" \
    --node-count "${node_count}" \
    --output none
}

status_gke() {
  echo "--- GKE nodes ---"
  gcloud container node-pools describe "${GKE_NODEPOOL}" \
    --cluster="${GKE_CLUSTER}" \
    --region="${GCP_REGION}" \
    --project="${GCP_PROJECT}" \
    --format="table(name,initialNodeCount,autoscaling.minNodeCount,autoscaling.maxNodeCount)" 2>/dev/null || echo "  (cluster not found)"
}

status_aks() {
  echo "--- AKS nodes ---"
  az aks nodepool list \
    --resource-group "${AZURE_RG}" \
    --cluster-name "${AKS_CLUSTER}" \
    --output table 2>/dev/null || echo "  (cluster not found)"
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd="${1:-help}"
check_deps

case "${cmd}" in
  up)
    echo "Scaling UP — bringing clusters to active state..."
    scale_gke 1 3
    scale_aks 1
    echo ""
    echo "Done. Get credentials:"
    echo "  gcloud container clusters get-credentials ${GKE_CLUSTER} --region ${GCP_REGION} --project ${GCP_PROJECT}"
    echo "  az aks get-credentials --resource-group ${AZURE_RG} --name ${AKS_CLUSTER}"
    ;;
  down)
    echo "Scaling DOWN — stopping compute to minimize cost..."
    scale_gke 0 3
    scale_aks 0
    echo ""
    echo "Done. Note: Cloud SQL and PostgreSQL Flexible Server continue to accrue"
    echo "storage charges (~\$0.10-0.20/GB/month). To stop them too:"
    echo "  terraform apply -var='cloudsql_tier=db-f1-micro' # already minimal"
    ;;
  status)
    status_gke
    echo ""
    status_aks
    ;;
  *)
    echo "Usage: $0 up|down|status"
    exit 1
    ;;
esac
