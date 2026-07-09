variable "name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "gateway_subnet_id" {
  type = string
}

variable "azure_bgp_asn" {
  type    = number
  default = 65515
}

variable "tags" {
  type    = map(string)
  default = {}
}
