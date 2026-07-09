output "vpn_connection_id" {
  value = aws_vpn_connection.to_azure.id
}

output "vpn_gateway_id" {
  value = aws_vpn_gateway.main.id
}

output "customer_gateway_id" {
  value = aws_customer_gateway.azure.id
}

output "tunnel1_address" {
  value = aws_vpn_connection.to_azure.tunnel1_address
}

output "tunnel2_address" {
  value = aws_vpn_connection.to_azure.tunnel2_address
}

output "tunnel1_preshared_key" {
  value     = aws_vpn_connection.to_azure.tunnel1_preshared_key
  sensitive = true
}

output "tunnel2_preshared_key" {
  value     = aws_vpn_connection.to_azure.tunnel2_preshared_key
  sensitive = true
}
