output "cluster_name" {
  value = google_container_cluster.main.name
}

output "cluster_endpoint" {
  value     = google_container_cluster.main.endpoint
  sensitive = true
}

output "cluster_ca_certificate" {
  value     = google_container_cluster.main.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "node_pool_name" {
  value = google_container_node_pool.app.name
}

output "node_service_account_email" {
  value = google_service_account.gke_nodes.email
}

output "workload_identity_pool" {
  value = "${var.project_id}.svc.id.goog"
}
