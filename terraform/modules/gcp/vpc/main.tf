###############################################################################
# GCP VPC — primary network for GKE and Cloud SQL
###############################################################################

resource "google_compute_network" "main" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "gke" {
  name          = "${var.name}-gke-subnet"
  ip_cidr_range = cidrsubnet(var.vpc_cidr, 4, 0) # e.g. 10.0.0.0/20
  region        = var.region
  network       = google_compute_network.main.id

  # Secondary ranges for GKE pods and services
  secondary_ip_range {
    range_name    = "${var.name}-pods"
    ip_cidr_range = cidrsubnet(var.vpc_cidr, 2, 1) # e.g. 10.0.64.0/18
  }

  secondary_ip_range {
    range_name    = "${var.name}-services"
    ip_cidr_range = cidrsubnet(var.vpc_cidr, 4, 2) # e.g. 10.0.32.0/20
  }

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "cloudsql" {
  name          = "${var.name}-db-subnet"
  ip_cidr_range = cidrsubnet(var.vpc_cidr, 4, 1) # e.g. 10.0.16.0/20
  region        = var.region
  network       = google_compute_network.main.id

  private_ip_google_access = true
}

# ── Cloud Router + NAT — gated behind var.enable_nat (~$32/month) ─────────────
# Prior billing incident: Cloud NAT charged even with no traffic. Default off.
resource "google_compute_router" "main" {
  count   = var.enable_nat ? 1 : 0
  name    = "${var.name}-router"
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  count                              = var.enable_nat ? 1 : 0
  name                               = "${var.name}-nat"
  router                             = google_compute_router.main[0].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ── VPN Gateway — for cross-cloud tunnel to Azure ─────────────────────────────
resource "google_compute_ha_vpn_gateway" "main" {
  count   = var.enable_vpn ? 1 : 0
  name    = "${var.name}-ha-vpn-gw"
  region  = var.region
  network = google_compute_network.main.id
}

# ── Firewall rules ─────────────────────────────────────────────────────────────
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.name}-allow-internal"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.vpc_cidr]
}

resource "google_compute_firewall" "allow_health_checks" {
  name    = "${var.name}-allow-health-checks"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }

  # Google health checker IP ranges
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

# ── Private Services Access — required for Cloud SQL private IP ────────────────
resource "google_compute_global_address" "private_services" {
  name          = "${var.name}-private-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private_services" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
}
