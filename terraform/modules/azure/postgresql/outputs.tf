output "server_id"       { value = azurerm_postgresql_flexible_server.main.id }
output "server_fqdn"     { value = azurerm_postgresql_flexible_server.main.fqdn }
output "server_name"     { value = azurerm_postgresql_flexible_server.main.name }
output "database_name"   { value = azurerm_postgresql_flexible_server_database.appdb.name }
