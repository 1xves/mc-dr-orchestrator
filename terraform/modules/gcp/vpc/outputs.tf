output "network_id" {
  value = google_compute_network.main.id
}

output "network_name" {
  value = google_compute_network.main.name
}

output "network_self_link" {
  value = google_compute_network.main.self_link
}

output "gke_subnet_name" {
  value = google_compute_subnetwork.gke.name
}

output "gke_subnet_self_link" {
  value = google_compute_subnetwork.gke.self_link
}

output "gke_pods_range_name" {
  value = "${var.name}-pods"
}

output "gke_services_range_name" {
  value = "${var.name}-services"
}

output "nat_enabled" {
  value       = var.enable_nat
  description = "Whether Cloud NAT is provisioned"
}

output "ha_vpn_gateway_id" {
  value = one(google_compute_ha_vpn_gateway.main[*].id)
}

output "ha_vpn_gateway_self_link" {
  value = one(google_compute_ha_vpn_gateway.main[*].self_link)
}

output "ha_vpn_gateway_vpn_interfaces" {
  value = one(google_compute_ha_vpn_gateway.main[*].vpn_interfaces)
}

output "private_services_connection" {
  value = google_service_networking_connection.private_services.id
}
