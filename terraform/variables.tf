###############################################################################
# Root variables — GCP primary + Azure standby DR Orchestrator
###############################################################################

# ── General ───────────────────────────────────────────────────────────────────
variable "project_name" {
  type        = string
  default     = "mc-dr"
  description = "Short prefix used for all resource names"
}

variable "environment" {
  type    = string
  default = "production"
}

# ── GCP ───────────────────────────────────────────────────────────────────────
variable "gcp_project_id" {
  type        = string
  description = "GCP project ID (not name) — find it in the Cloud Console dashboard"
}

variable "gcp_region" {
  type        = string
  default     = "us-central1"
  description = "Primary GCP region — us-central1 has lowest cost and broadest service availability"
}

variable "gcp_zone" {
  type        = string
  default     = "us-central1-a"
  description = "Single zone for GKE — zonal cluster has no management fee (first cluster per billing account is free)"
}

variable "gcp_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "gke_node_machine_type" {
  type        = string
  default     = "e2-standard-2"
  description = "GKE node VM type — e2-standard-2 (2 vCPU, 8GB) balances cost and capacity"
}

variable "gke_node_min_count" {
  type        = number
  default     = 0
  description = "Min nodes per zone — 0 lets you scale to zero for cost savings"
}

variable "gke_node_max_count" {
  type    = number
  default = 3
}

variable "gke_node_initial_count" {
  type        = number
  default     = 0
  description = "Start at 0 — scale up via scale.sh when needed"
}

variable "kubernetes_version_gcp" {
  type    = string
  default = "1.34" # 1.32 no longer offered in GKE us-central1 (STABLE is 1.34.x)
}

variable "cloudsql_tier" {
  type        = string
  default     = "db-f1-micro"
  description = "Cloud SQL instance tier — db-f1-micro is cheapest; upgrade to db-g1-small or db-n1-standard-1 for production load"
}

variable "cloudsql_db_version" {
  type    = string
  default = "POSTGRES_15"
}

variable "gcp_state_bucket" {
  type        = string
  description = "GCS bucket name for Terraform state (created by bootstrap_gcs.sh)"
}

# ── Azure ─────────────────────────────────────────────────────────────────────
variable "azure_location" {
  type        = string
  default     = "eastus2"
  description = "Azure region for standby resources — eastus2 avoids the restricted eastus zone"
}

variable "azure_vnet_cidr" {
  type        = string
  default     = "10.1.0.0/16"
  description = "Must not overlap with gcp_vpc_cidr for VPN routing"
}

variable "aks_node_vm_size" {
  type        = string
  default     = "Standard_B2s_v2"
  description = "AKS node VM size — B2s_v2 (2 vCPU, 8GB burstable); B2s(v1) is not offered in some subs/regions"
}

variable "aks_node_min_count" {
  type    = number
  default = 0
}

variable "aks_node_max_count" {
  type    = number
  default = 3
}

variable "aks_node_initial_count" {
  type        = number
  default     = 0
  description = "Start at 0 — scale up via scale.sh when needed"
}

variable "kubernetes_version_azure" {
  type    = string
  default = "1.34" # 1.32 is LTS-only in AKS; use a standard supported version
}

variable "azure_postgresql_sku" {
  type        = string
  default     = "B_Standard_B1ms"
  description = "PostgreSQL Flexible Server SKU — B_Standard_B1ms is cheapest burstable tier for standby"
}

# ── Database ──────────────────────────────────────────────────────────────────
variable "db_name" {
  type    = string
  default = "drapp"
}

# NOTE: db_master_password was removed. The Postgres credential is no longer
# a Terraform concern; ansible/deploy_postgres.yml reads DB_MASTER_PASSWORD
# from the environment at deploy time.

# ── Alerting ──────────────────────────────────────────────────────────────────
variable "alert_email" {
  type        = string
  description = "Email address for DR alert notifications"
}

variable "slack_webhook_url" {
  type      = string
  default   = ""
  sensitive = true
}

# ── DNS / Routing (optional) ──────────────────────────────────────────────────
variable "domain_name" {
  type        = string
  default     = ""
  description = "Root domain for Cloud DNS records — leave empty to skip DNS setup"
}

variable "primary_endpoint_fqdn" {
  type        = string
  default     = "placeholder.example.com"
  description = "FQDN polled by health_monitor — update after GKE ingress IP is known"
}

# ── Cost guards — ALL default off; enable deliberately ────────────────────────
# These flags exist because of two prior billing incidents ($245 GCP Feature Store
# + $140 AWS VPN). Expensive resources are gated and never provision by accident.

variable "enable_vpn" {
  type        = bool
  default     = false
  description = "Provision Azure VPN Gateway + GCP HA VPN tunnels. ~$210/month combined. Enable only when demonstrating cross-cloud connectivity."
}

variable "enable_nat" {
  type        = bool
  default     = false
  description = "Provision GCP Cloud NAT. ~$32/month. Required for private GKE nodes to pull images. Enable with enable_vpn or when running workloads."
}

variable "gcp_billing_budget_amount" {
  type        = number
  default     = 50
  description = "Monthly GCP billing budget in USD — alert fires at 50% and 90%"
}

variable "gcp_billing_account_id" {
  type        = string
  default     = ""
  description = "GCP billing account ID (format: XXXXXX-XXXXXX-XXXXXX) — required for budget alerts"
}
