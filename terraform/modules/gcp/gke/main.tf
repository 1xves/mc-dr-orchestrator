###############################################################################
# GKE Standard cluster — private nodes, Workload Identity, cluster autoscaler
###############################################################################

# Service account for GKE nodes (least-privilege)
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "GKE Node Service Account — ${var.cluster_name}"
}

resource "google_project_iam_member" "gke_nodes_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_container_cluster" "main" {
  name     = var.cluster_name
  location = var.zone   # zonal cluster = $0 management fee (first cluster per billing account is free)

  # Remove default node pool — we manage our own below
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network_name
  subnetwork = var.subnet_name

  # Private cluster — nodes have no public IPs
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false        # keeps kubectl access from your machine
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Workload Identity — pods get GCP IAM roles without key files
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Master auth — disable basic auth and client certs
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  min_master_version = var.kubernetes_version

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
    network_policy_config {
      disabled = false
    }
  }

  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  release_channel {
    channel = "REGULAR"
  }

  maintenance_policy {
    recurring_window {
      start_time = "2024-01-01T09:00:00Z"
      end_time   = "2024-01-01T13:00:00Z"
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }
  }

  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  resource_labels = var.labels
}

resource "google_container_node_pool" "app" {
  name       = "${var.cluster_name}-app"
  location   = var.zone
  cluster    = google_container_cluster.main.name

  initial_node_count = var.node_initial_count

  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = 50
    disk_type    = "pd-standard"

    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    # Workload Identity on node pool
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    labels = var.labels

    tags = ["gke-node", var.cluster_name]
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}
