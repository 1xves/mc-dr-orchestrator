###############################################################################
# AWS VPN Module — Site-to-site VPN to Azure VNet
###############################################################################

# ── Customer Gateway (represents Azure VPN endpoint) ─────────────────────────
resource "aws_customer_gateway" "azure" {
  bgp_asn    = var.azure_bgp_asn
  ip_address = var.azure_vpn_gateway_ip
  type       = "ipsec.1"
  tags       = merge(var.tags, { Name = "${var.name}-azure-cgw" })
}

# ── Virtual Private Gateway ───────────────────────────────────────────────────
resource "aws_vpn_gateway" "main" {
  vpc_id          = var.vpc_id
  amazon_side_asn = var.aws_bgp_asn
  tags            = merge(var.tags, { Name = "${var.name}-vgw" })
}

resource "aws_vpn_gateway_attachment" "main" {
  vpc_id         = var.vpc_id
  vpn_gateway_id = aws_vpn_gateway.main.id
}

# ── Propagate routes to private route tables ──────────────────────────────────
resource "aws_vpn_gateway_route_propagation" "private" {
  count          = length(var.private_route_table_ids)
  vpn_gateway_id = aws_vpn_gateway.main.id
  route_table_id = var.private_route_table_ids[count.index]
}

# ── VPN Connection ────────────────────────────────────────────────────────────
resource "aws_vpn_connection" "to_azure" {
  vpn_gateway_id      = aws_vpn_gateway.main.id
  customer_gateway_id = aws_customer_gateway.azure.id
  type                = "ipsec.1"
  static_routes_only  = false # use BGP

  tunnel1_ike_versions                 = ["ikev2"]
  tunnel2_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_dh_group_numbers      = [14]
  tunnel2_phase2_dh_group_numbers      = [14]

  tags = merge(var.tags, { Name = "${var.name}-to-azure" })
}

# BGP is used for routing — static connection routes are not applicable here.
# Routes are propagated automatically via VPN gateway route propagation above.

# ── CloudWatch Alarms — tunnel health ────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "tunnel1_state" {
  alarm_name          = "${var.name}-vpn-tunnel1-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TunnelState"
  namespace           = "AWS/VPN"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "VPN Tunnel 1 to Azure is DOWN"
  alarm_actions       = var.alarm_sns_arn != "" ? [var.alarm_sns_arn] : []
  dimensions = {
    VpnId    = aws_vpn_connection.to_azure.id
    TunnelIp = aws_vpn_connection.to_azure.tunnel1_address
  }
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "tunnel2_state" {
  alarm_name          = "${var.name}-vpn-tunnel2-down"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "TunnelState"
  namespace           = "AWS/VPN"
  period              = 60
  statistic           = "Maximum"
  threshold           = 1
  alarm_description   = "VPN Tunnel 2 to Azure is DOWN"
  alarm_actions       = var.alarm_sns_arn != "" ? [var.alarm_sns_arn] : []
  dimensions = {
    VpnId    = aws_vpn_connection.to_azure.id
    TunnelIp = aws_vpn_connection.to_azure.tunnel2_address
  }
  tags = var.tags
}
