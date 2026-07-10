variable "server_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "subnet_id" {
  type = string
}

variable "private_dns_zone_id" {
  type = string
}

variable "pg_version" {
  type    = string
  default = "15"
}

variable "sku_name" {
  type        = string
  default     = "B_Standard_B1ms"
  description = "Burstable B_Standard_B1ms is cheapest; upgrade to GP_Standard_D2s_v3 for production"
}

variable "storage_mb" {
  type    = number
  default = 32768   # 32 GB minimum
}

variable "db_name" {
  type    = string
  default = "drapp"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
