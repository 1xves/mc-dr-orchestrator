variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "azure_vpn_gateway_ip" {
  type        = string
  description = "Azure VPN Gateway public IP"
}

variable "azure_vnet_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "azure_bgp_asn" {
  type    = number
  default = 65515
}

variable "aws_bgp_asn" {
  type    = number
  default = 64512
}

variable "private_route_table_ids" {
  type = list(string)
}

variable "alarm_sns_arn" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
