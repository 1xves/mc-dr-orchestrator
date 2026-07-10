variable "name" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "region" {
  type = string
}

variable "enable_nat" {
  type        = bool
  default     = false
  description = "Provision Cloud NAT. ~$32/month. Required for private nodes to reach internet."
}

variable "enable_vpn" {
  type        = bool
  default     = false
  description = "Provision the HA VPN gateway (cross-cloud tunnel to Azure). Gated so enable_vpn=false leaves zero VPN resources."
}

variable "tags" {
  type    = map(string)
  default = {}
}
