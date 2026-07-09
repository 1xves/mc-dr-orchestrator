###############################################################################
# Azure AKS Module — Standby cluster, scaled to zero until failover
###############################################################################

# ── Log Analytics for monitoring ──────────────────────────────────────────────
resource "azurerm_log_analytics_workspace" "aks" {
  name                = "${var.cluster_name}-logs"
  location            = var.location
  resource_group_name = var.resource_group_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ── AKS Cluster ───────────────────────────────────────────────────────────────
resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  # Default system node pool — always has at least 1 node for control plane
  default_node_pool {
    name                = "system"
    node_count          = 1 # Minimum required; application workloads use user pool
    vm_size             = "Standard_DC4s_v3"
    vnet_subnet_id      = var.aks_subnet_id
    type                = "VirtualMachineScaleSets"
    enable_auto_scaling = false

    node_labels = {
      "nodepool-type" = "system"
      "environment"   = var.environment
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "calico"
    load_balancer_sku = "standard"
    service_cidr      = "172.16.0.0/16"
    dns_service_ip    = "172.16.0.10"
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id
  }

  azure_policy_enabled             = true
  http_application_routing_enabled = false

  tags = var.tags
}

# ── Application Node Pool — scaled to ZERO at standby ────────────────────────
# During standby: node_count = 0 (no cost for VM compute)
# During failover: scale to var.failover_node_count via health monitor script
resource "azurerm_kubernetes_cluster_node_pool" "app" {
  name                  = "app"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = var.node_vm_size
  node_count            = var.standby_node_count # 0 during normal operation
  vnet_subnet_id        = var.aks_subnet_id
  enable_auto_scaling   = false
  mode                  = "User"
  os_disk_size_gb       = 50

  node_labels = {
    "nodepool-type" = "application"
    "environment"   = var.environment
    "role"          = "dr-standby"
  }

  node_taints = var.standby_node_count == 0 ? ["dr-standby=true:NoSchedule"] : []

  tags = var.tags

  lifecycle {
    ignore_changes = [node_count, node_taints]
  }
}

# ── Container Registry pull permissions ───────────────────────────────────────
resource "azurerm_role_assignment" "acr_pull" {
  count                = var.container_registry_id != "" ? 1 : 0
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  role_definition_name = "AcrPull"
  scope                = var.container_registry_id
}

# ── Diagnostic settings ───────────────────────────────────────────────────────
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                       = "${var.cluster_name}-diagnostics"
  target_resource_id         = azurerm_kubernetes_cluster.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.aks.id

  enabled_log { category = "kube-apiserver" }
  enabled_log { category = "kube-controller-manager" }
  enabled_log { category = "kube-scheduler" }
  enabled_log { category = "kube-audit" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# ── Metric Alerts ─────────────────────────────────────────────────────────────
resource "azurerm_monitor_metric_alert" "aks_node_cpu" {
  name                = "${var.cluster_name}-high-node-cpu"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_kubernetes_cluster.main.id]
  description         = "AKS node CPU exceeded 80%"
  severity            = 2
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.ContainerService/managedClusters"
    metric_name      = "node_cpu_usage_percentage"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  tags = var.tags
}
