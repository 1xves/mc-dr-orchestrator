###############################################################################
# Root Terraform — GCP primary + Azure standby DR Orchestrator
# Database: containerized Postgres (StatefulSet + PVC) on each cluster
# Cost at rest: ~$0.80/month (two 10GB persistent disks, nodes scaled to 0)
###############################################################################

locals {
  common_labels = {
    project     = var.project_name
    managed_by  = "terraform"
    environment = var.environment
  }

  common_tags = {
    Project     = var.project_name
    ManagedBy   = "terraform"
    Environment = var.environment
  }
}

# ── Required APIs (GCP) ───────────────────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "pubsub.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudfunctions.googleapis.com", # Gen1 billing-stopper function
    "cloudbuild.googleapis.com",     # builds the function source zip
  ])

  project            = var.gcp_project_id
  service            = each.value
  disable_on_destroy = false
}

# ── GCP VPC ───────────────────────────────────────────────────────────────────
module "gcp_vpc" {
  source = "./modules/gcp/vpc"

  name       = "${var.project_name}-primary"
  vpc_cidr   = var.gcp_vpc_cidr
  region     = var.gcp_region
  enable_nat = var.enable_nat # default false — ~$32/month when on
  enable_vpn = var.enable_vpn # default false — gates the HA VPN gateway
  tags       = local.common_labels

  depends_on = [google_project_service.apis]
}

# ── GKE (primary Kubernetes) ──────────────────────────────────────────────────
module "gcp_gke" {
  source = "./modules/gcp/gke"

  cluster_name        = "${var.project_name}-gke"
  project_id          = var.gcp_project_id
  region              = var.gcp_region
  zone                = var.gcp_zone # zonal = $0 management fee (first cluster free)
  network_name        = module.gcp_vpc.network_name
  subnet_name         = module.gcp_vpc.gke_subnet_name
  pods_range_name     = module.gcp_vpc.gke_pods_range_name
  services_range_name = module.gcp_vpc.gke_services_range_name
  kubernetes_version  = var.kubernetes_version_gcp
  node_machine_type   = var.gke_node_machine_type
  node_min_count      = var.gke_node_min_count
  node_max_count      = var.gke_node_max_count
  node_initial_count  = var.gke_node_initial_count
  labels              = local.common_labels
}

# ── GCP Pub/Sub alerting ──────────────────────────────────────────────────────
resource "google_pubsub_topic" "dr_alerts" {
  name    = "${var.project_name}-dr-alerts"
  project = var.gcp_project_id
  labels  = local.common_labels
}

resource "google_pubsub_subscription" "dr_alerts_email" {
  name    = "${var.project_name}-dr-alerts-email"
  topic   = google_pubsub_topic.dr_alerts.name
  project = var.gcp_project_id

  message_retention_duration = "86400s"
  retain_acked_messages      = false
  ack_deadline_seconds       = 60

  expiration_policy {
    ttl = "86400s"
  }
}

# Cloud Monitoring alert policy — GKE node count drop
resource "google_monitoring_alert_policy" "gke_node_count" {
  display_name = "${var.project_name} GKE node count critical"
  project      = var.gcp_project_id
  combiner     = "OR"

  conditions {
    display_name = "GKE node count below threshold"
    condition_threshold {
      filter          = "resource.type=\"k8s_node\" AND metric.type=\"kubernetes.io/node/cpu/allocatable_cores\""
      duration        = "120s"
      comparison      = "COMPARISON_LT"
      threshold_value = 1

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_COUNT"
      }
    }
  }

  notification_channels = []
  user_labels           = local.common_labels
}

# ── Azure VNet ────────────────────────────────────────────────────────────────
module "azure_vnet" {
  source = "./modules/azure/vnet"

  name      = "${var.project_name}-standby"
  location  = var.azure_location
  vnet_cidr = var.azure_vnet_cidr
  tags      = local.common_tags
}

# ── AKS (standby Kubernetes) ──────────────────────────────────────────────────
module "azure_aks" {
  source = "./modules/azure/aks"

  cluster_name        = "${var.project_name}-aks"
  location            = var.azure_location
  resource_group_name = module.azure_vnet.resource_group_name
  subnet_id           = module.azure_vnet.aks_subnet_id
  kubernetes_version  = var.kubernetes_version_azure
  node_vm_size        = var.aks_node_vm_size
  node_min_count      = var.aks_node_min_count
  node_max_count      = var.aks_node_max_count
  node_initial_count  = var.aks_node_initial_count
  tags                = local.common_tags
}

# ── Cross-cloud VPN — gated behind var.enable_vpn (default false) ─────────────
# Cost: Azure VPN Gateway ~$140/mo + GCP tunnels ~$72/mo = ~$210/mo combined.
# Prior incident: $140 AWS bill from VPN Gateway running unguarded.
# Enable only when demonstrating cross-cloud connectivity. Destroy after demo.

resource "random_password" "vpn_psk" {
  count   = var.enable_vpn ? 1 : 0
  length  = 32
  special = false
}

resource "azurerm_public_ip" "vpn" {
  count               = var.enable_vpn ? 1 : 0
  name                = "${var.project_name}-vpn-pip"
  resource_group_name = module.azure_vnet.resource_group_name
  location            = var.azure_location
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1"]
  tags                = local.common_tags
}

resource "azurerm_virtual_network_gateway" "main" {
  count               = var.enable_vpn ? 1 : 0
  name                = "${var.project_name}-vpn-gw"
  resource_group_name = module.azure_vnet.resource_group_name
  location            = var.azure_location
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw1"
  enable_bgp          = true
  active_active       = false
  tags                = local.common_tags

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn[0].id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = module.azure_vnet.gateway_subnet_id
  }

  bgp_settings {
    asn = 65515
  }
}

resource "google_compute_router" "vpn" {
  count   = var.enable_vpn ? 1 : 0
  name    = "${var.project_name}-vpn-router"
  region  = var.gcp_region
  network = module.gcp_vpc.network_name

  bgp {
    asn               = 65516
    advertise_mode    = "CUSTOM"
    advertised_groups = ["ALL_SUBNETS"]
  }
}

resource "google_compute_external_vpn_gateway" "azure" {
  count           = var.enable_vpn ? 1 : 0
  name            = "${var.project_name}-azure-ext-gw"
  redundancy_type = "SINGLE_IP_INTERNALLY_REDUNDANT"

  interface {
    id         = 0
    ip_address = azurerm_public_ip.vpn[0].ip_address
  }
}

resource "google_compute_vpn_tunnel" "to_azure_0" {
  count                           = var.enable_vpn ? 1 : 0
  name                            = "${var.project_name}-to-azure-0"
  region                          = var.gcp_region
  vpn_gateway                     = module.gcp_vpc.ha_vpn_gateway_self_link
  vpn_gateway_interface           = 0
  peer_external_gateway           = google_compute_external_vpn_gateway.azure[0].self_link
  peer_external_gateway_interface = 0
  shared_secret                   = random_password.vpn_psk[0].result
  router                          = google_compute_router.vpn[0].name
  ike_version                     = 2
}

resource "google_compute_vpn_tunnel" "to_azure_1" {
  count                           = var.enable_vpn ? 1 : 0
  name                            = "${var.project_name}-to-azure-1"
  region                          = var.gcp_region
  vpn_gateway                     = module.gcp_vpc.ha_vpn_gateway_self_link
  vpn_gateway_interface           = 1
  peer_external_gateway           = google_compute_external_vpn_gateway.azure[0].self_link
  peer_external_gateway_interface = 0
  shared_secret                   = random_password.vpn_psk[0].result
  router                          = google_compute_router.vpn[0].name
  ike_version                     = 2
}

resource "google_compute_router_interface" "tunnel_0" {
  count      = var.enable_vpn ? 1 : 0
  name       = "${var.project_name}-iface-0"
  router     = google_compute_router.vpn[0].name
  region     = var.gcp_region
  vpn_tunnel = google_compute_vpn_tunnel.to_azure_0[0].name
  ip_range   = "169.254.21.1/30"
}

resource "google_compute_router_interface" "tunnel_1" {
  count      = var.enable_vpn ? 1 : 0
  name       = "${var.project_name}-iface-1"
  router     = google_compute_router.vpn[0].name
  region     = var.gcp_region
  vpn_tunnel = google_compute_vpn_tunnel.to_azure_1[0].name
  ip_range   = "169.254.21.5/30"
}

resource "google_compute_router_peer" "azure_0" {
  count                     = var.enable_vpn ? 1 : 0
  name                      = "${var.project_name}-peer-azure-0"
  router                    = google_compute_router.vpn[0].name
  region                    = var.gcp_region
  interface                 = google_compute_router_interface.tunnel_0[0].name
  peer_ip_address           = "169.254.21.2"
  peer_asn                  = 65515
  advertised_route_priority = 100
}

resource "google_compute_router_peer" "azure_1" {
  count                     = var.enable_vpn ? 1 : 0
  name                      = "${var.project_name}-peer-azure-1"
  router                    = google_compute_router.vpn[0].name
  region                    = var.gcp_region
  interface                 = google_compute_router_interface.tunnel_1[0].name
  peer_ip_address           = "169.254.21.6"
  peer_asn                  = 65515
  advertised_route_priority = 100
}

resource "azurerm_local_network_gateway" "gcp_0" {
  count               = var.enable_vpn ? 1 : 0
  name                = "${var.project_name}-lng-gcp-0"
  resource_group_name = module.azure_vnet.resource_group_name
  location            = var.azure_location
  gateway_address     = module.gcp_vpc.ha_vpn_gateway_vpn_interfaces[0].ip_address
  tags                = local.common_tags

  bgp_settings {
    asn                 = 65516
    bgp_peering_address = "169.254.21.1"
  }
}

resource "azurerm_local_network_gateway" "gcp_1" {
  count               = var.enable_vpn ? 1 : 0
  name                = "${var.project_name}-lng-gcp-1"
  resource_group_name = module.azure_vnet.resource_group_name
  location            = var.azure_location
  gateway_address     = module.gcp_vpc.ha_vpn_gateway_vpn_interfaces[1].ip_address
  tags                = local.common_tags

  bgp_settings {
    asn                 = 65516
    bgp_peering_address = "169.254.21.5"
  }
}

resource "azurerm_virtual_network_gateway_connection" "to_gcp_0" {
  count               = var.enable_vpn ? 1 : 0
  name                = "${var.project_name}-conn-gcp-0"
  resource_group_name = module.azure_vnet.resource_group_name
  location            = var.azure_location
  type                = "IPsec"

  virtual_network_gateway_id = azurerm_virtual_network_gateway.main[0].id
  local_network_gateway_id   = azurerm_local_network_gateway.gcp_0[0].id

  shared_key = random_password.vpn_psk[0].result
  enable_bgp = true
  tags       = local.common_tags
}

resource "azurerm_virtual_network_gateway_connection" "to_gcp_1" {
  count               = var.enable_vpn ? 1 : 0
  name                = "${var.project_name}-conn-gcp-1"
  resource_group_name = module.azure_vnet.resource_group_name
  location            = var.azure_location
  type                = "IPsec"

  virtual_network_gateway_id = azurerm_virtual_network_gateway.main[0].id
  local_network_gateway_id   = azurerm_local_network_gateway.gcp_1[0].id

  shared_key = random_password.vpn_psk[0].result
  enable_bgp = true
  tags       = local.common_tags
}

# ── Auto-deploy Postgres to GKE after cluster is ready ───────────────────────
# Runs kubectl apply automatically as part of terraform apply.
# Triggers re-run only if the cluster is recreated (name changes).
resource "null_resource" "gke_postgres" {
  depends_on = [module.gcp_gke]

  triggers = {
    cluster_name = module.gcp_gke.cluster_name
    zone         = var.gcp_zone
    project      = var.gcp_project_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "==> Getting GKE credentials..."
      gcloud container clusters get-credentials ${module.gcp_gke.cluster_name} \
        --zone ${var.gcp_zone} \
        --project ${var.gcp_project_id}

      echo "==> Deploying Postgres namespace and manifests..."
      kubectl apply -f ${path.module}/../k8s/gcp/postgres/namespace.yaml

      echo "==> Creating Postgres secret (idempotent)..."
      kubectl create secret generic postgres-credentials \
        --namespace=database \
        --from-literal=POSTGRES_USER=drapp \
        --from-literal=POSTGRES_DB=drapp \
        --from-literal=POSTGRES_PASSWORD=${var.db_master_password} \
        --dry-run=client -o yaml | kubectl apply -f -

      echo "==> Applying StatefulSet and Services..."
      kubectl apply -f ${path.module}/../k8s/gcp/postgres/statefulset.yaml
      kubectl apply -f ${path.module}/../k8s/gcp/postgres/service.yaml

      echo "==> Waiting for Postgres pod to be ready..."
      kubectl rollout status statefulset/postgres --namespace=database --timeout=300s

      echo "==> GKE Postgres ready."
    EOT
  }
}

# ── Auto-deploy Postgres to AKS after cluster is ready ────────────────────────
resource "null_resource" "aks_postgres" {
  depends_on = [module.azure_aks]

  triggers = {
    cluster_name   = module.azure_aks.cluster_name
    resource_group = module.azure_vnet.resource_group_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      echo "==> Getting AKS credentials..."
      az aks get-credentials \
        --name ${module.azure_aks.cluster_name} \
        --resource-group ${module.azure_vnet.resource_group_name} \
        --overwrite-existing

      echo "==> Deploying Postgres namespace and manifests..."
      kubectl apply -f ${path.module}/../k8s/azure/postgres/namespace.yaml

      echo "==> Creating Postgres secret (idempotent)..."
      kubectl create secret generic postgres-credentials \
        --namespace=database \
        --from-literal=POSTGRES_USER=drapp \
        --from-literal=POSTGRES_DB=drapp \
        --from-literal=POSTGRES_PASSWORD=${var.db_master_password} \
        --dry-run=client -o yaml | kubectl apply -f -

      echo "==> Applying StatefulSet and Services..."
      kubectl apply -f ${path.module}/../k8s/azure/postgres/statefulset.yaml
      kubectl apply -f ${path.module}/../k8s/azure/postgres/service.yaml

      echo "==> Waiting for Postgres pod to be ready..."
      kubectl rollout status statefulset/postgres --namespace=database --timeout=300s

      echo "==> AKS Postgres ready."
    EOT
  }
}

# ── GCP Billing Budget — fires alert before charges accumulate ─────────────────
# Lesson from $245 Feature Store incident: budget alert is non-negotiable.
resource "google_billing_budget" "main" {
  count           = var.gcp_billing_account_id != "" ? 1 : 0
  billing_account = var.gcp_billing_account_id
  display_name    = "${var.project_name}-monthly-budget"

  budget_filter {
    projects = ["projects/${var.gcp_project_id}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.gcp_billing_budget_amount)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  # Publish to dedicated billing-alerts topic — consumed by billing_stopper (kill-switch)
  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.billing_alerts[0].id
    schema_version = "1.0"
  }
}
