###############################################################################
# Azure Database for PostgreSQL Flexible Server — DR Replica
# Public endpoint (no VNet delegation) so it can deploy in eastus2 while the
# VNet lives in eastus. Access is locked down via firewall rules.
###############################################################################

resource "azurerm_postgresql_flexible_server" "main" {
  name                   = var.server_name
  resource_group_name    = var.resource_group_name
  location               = var.location
  version                = var.pg_version
  administrator_login    = var.administrator_login
  administrator_password = var.administrator_password
  zone                   = "1"

  storage_mb   = var.storage_mb
  storage_tier = "P30"

  sku_name = var.sku_name

  backup_retention_days        = var.backup_retention_days
  geo_redundant_backup_enabled = false # cross-cloud replication handled by pglogical
  auto_grow_enabled            = true

  # No VNet integration — using public endpoint restricted by firewall rules below.
  # High availability omitted: ZoneRedundant HA requires VNet integration.

  maintenance_window {
    day_of_week  = 0
    start_hour   = 3
    start_minute = 0
  }

  tags = var.tags
}

# ── Firewall — allow AWS VPC CIDR (traffic arrives over site-to-site VPN) ────
resource "azurerm_postgresql_flexible_server_firewall_rule" "aws_vpc" {
  name             = "allow-aws-vpc"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = cidrhost(var.aws_vpc_cidr, 0)
  end_ip_address   = cidrhost(var.aws_vpc_cidr, -1)
}

# ── pglogical configuration ───────────────────────────────────────────────────
resource "azurerm_postgresql_flexible_server_configuration" "shared_preload_libraries" {
  name      = "shared_preload_libraries"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "pglogical"
}

resource "azurerm_postgresql_flexible_server_configuration" "wal_level" {
  name      = "wal_level"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "logical"
}

resource "azurerm_postgresql_flexible_server_configuration" "max_replication_slots" {
  name      = "max_replication_slots"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "10"
}

resource "azurerm_postgresql_flexible_server_configuration" "max_wal_senders" {
  name      = "max_wal_senders"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "10"
}

# ── Application Database ──────────────────────────────────────────────────────
resource "azurerm_postgresql_flexible_server_database" "appdb" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# ── Diagnostic settings ───────────────────────────────────────────────────────
resource "azurerm_monitor_diagnostic_setting" "postgresql" {
  name                       = "${var.server_name}-diagnostics"
  target_resource_id         = azurerm_postgresql_flexible_server.main.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "PostgreSQLLogs" }
  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

# ── Replication lag alert ─────────────────────────────────────────────────────
resource "azurerm_monitor_metric_alert" "replication_lag" {
  name                = "${var.server_name}-replication-lag"
  resource_group_name = var.resource_group_name
  scopes              = [azurerm_postgresql_flexible_server.main.id]
  description         = "pglogical replication lag exceeded 30 seconds — RPO at risk"
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "replication_lag"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 30
  }

  dynamic "action" {
    for_each = var.action_group_id != "" ? [1] : []
    content {
      action_group_id = var.action_group_id
    }
  }

  tags = var.tags
}
