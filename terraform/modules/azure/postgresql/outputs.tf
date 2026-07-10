output "server_name" {
  value = azurerm_postgresql_flexible_server.main.name
}

output "server_id" {
  value = azurerm_postgresql_flexible_server.main.id
}

output "fqdn" {
  value = azurerm_postgresql_flexible_server.main.fqdn
}

output "database_name" {
  value = azurerm_postgresql_flexible_server_database.app.name
}

output "administrator_login" {
  value = azurerm_postgresql_flexible_server.main.administrator_login
}
