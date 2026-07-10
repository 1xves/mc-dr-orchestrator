###############################################################################
# Azure PostgreSQL Flexible Server — standby DB, burstable tier
###############################################################################

resource "azurerm_postgresql_flexible_server" "main" {
  name                   = var.server_name
  resource_group_name    = var.resource_group_name
  location               = var.location
  version                = var.pg_version
  delegated_subnet_id    = var.subnet_id
  private_dns_zone_id    = var.private_dns_zone_id
  administrator_login    = "drapp"
  administrator_password = var.db_password
  sku_name               = var.sku_name
  storage_mb             = var.storage_mb
  zone                   = "1"

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false   # standby — backups stay local

  tags = var.tags
}

resource "azurerm_postgresql_flexible_server_database" "app" {
  name      = var.db_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "utf8"
}

# Allow internal VNet traffic only — no public firewall rules needed
resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  name      = "log_connections"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_disconnections" {
  name      = "log_disconnections"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "on"
}
