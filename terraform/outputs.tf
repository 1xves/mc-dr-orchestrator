###############################################################################
# Root outputs — GCP primary + Azure standby
###############################################################################

# ── GCP ───────────────────────────────────────────────────────────────────────
output "gke_cluster_name" {
  value       = module.gcp_gke.cluster_name
  description = "Run: gcloud container clusters get-credentials <name> --zone <zone> --project <project>"
}

output "gke_cluster_endpoint" {
  value     = module.gcp_gke.cluster_endpoint
  sensitive = true
}

output "pubsub_topic" {
  value = google_pubsub_topic.dr_alerts.name
}

# ── Azure ─────────────────────────────────────────────────────────────────────
output "aks_cluster_name" {
  value       = module.azure_aks.cluster_name
  description = "Run: az aks get-credentials --name <name> --resource-group <rg>"
}

output "azure_resource_group" {
  value = module.azure_vnet.resource_group_name
}

# ── Database (containerized — auto-deployed via null_resource) ────────────────
output "postgres_connection_gke" {
  value       = "postgres://drapp@postgres.database.svc.cluster.local:5432/drapp"
  description = "Internal connection string for GKE — use after nodes are scaled up"
}

output "postgres_connection_aks" {
  value       = "postgres://drapp@postgres.database.svc.cluster.local:5432/drapp"
  description = "Internal connection string for AKS — use after nodes are scaled up"
}

# ── VPN (conditional) ─────────────────────────────────────────────────────────
output "azure_vpn_gateway_ip" {
  value       = var.enable_vpn ? azurerm_public_ip.vpn[0].ip_address : "VPN disabled (enable_vpn=false)"
  description = "Azure VPN Gateway public IP — only populated when enable_vpn=true"
}

output "gcp_vpn_gateway_ips" {
  value       = module.gcp_vpc.ha_vpn_gateway_vpn_interfaces
  description = "GCP HA VPN gateway interface IPs"
}
