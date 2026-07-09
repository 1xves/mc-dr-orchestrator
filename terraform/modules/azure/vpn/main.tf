###############################################################################
# Azure VPN Module — VPN Gateway (dev-sized: VpnGw1, single endpoint)
###############################################################################

# ── Public IP for VPN Gateway ─────────────────────────────────────────────────
resource "azurerm_public_ip" "vpn" {
  name                = "${var.name}-vpn-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ── VPN Gateway (VpnGw1 — BGP capable, no zone redundancy, ~$140/mo cheaper) ─
resource "azurerm_virtual_network_gateway" "main" {
  name                = "${var.name}-vng"
  location            = var.location
  resource_group_name = var.resource_group_name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw1"
  active_active       = false
  enable_bgp          = true

  bgp_settings {
    asn = var.azure_bgp_asn
  }

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn.id
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = var.gateway_subnet_id
  }

  tags = var.tags
}
