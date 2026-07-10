output "resource_group_name" {
  value = azurerm_resource_group.main.name
}

output "vnet_id" {
  value = azurerm_virtual_network.main.id
}

output "vnet_name" {
  value = azurerm_virtual_network.main.name
}

output "aks_subnet_id" {
  value = azurerm_subnet.aks.id
}

output "postgresql_subnet_id" {
  value = azurerm_subnet.postgresql.id
}

output "gateway_subnet_id" {
  value = azurerm_subnet.gateway.id
}

output "postgresql_dns_zone_id" {
  value = azurerm_private_dns_zone.postgresql.id
}

output "postgresql_dns_zone_name" {
  value = azurerm_private_dns_zone.postgresql.name
}
