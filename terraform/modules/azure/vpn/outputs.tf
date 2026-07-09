output "vpn_gateway_id" {
  value = azurerm_virtual_network_gateway.main.id
}

output "vpn_gateway_public_ip" {
  value = azurerm_public_ip.vpn.ip_address
}

output "vpn_gateway_active_ip" {
  value       = azurerm_public_ip.vpn.ip_address
  description = "Alias for active IP — same as primary since active_active=false on VpnGw1"
}
