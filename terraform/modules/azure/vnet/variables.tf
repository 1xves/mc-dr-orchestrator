variable "name" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "vnet_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "tags" {
  type    = map(string)
  default = {}
}
