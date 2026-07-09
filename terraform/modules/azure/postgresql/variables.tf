variable "server_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "pg_version" {
  type    = string
  default = "15"
}

variable "postgresql_subnet_id" {
  type    = string
  default = ""
  description = "Unused — kept for compatibility. VNet integration removed due to cross-region constraint."
}

variable "private_dns_zone_id" {
  type    = string
  default = ""
  description = "Unused — kept for compatibility. VNet integration removed due to cross-region constraint."
}

variable "administrator_login" {
  type    = string
  default = "dbadmin"
}

variable "administrator_password" {
  type      = string
  sensitive = true
}

variable "storage_mb" {
  type    = number
  default = 131072
}

variable "sku_name" {
  type    = string
  default = "GP_Standard_D2s_v3"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "high_availability_mode" {
  type    = string
  default = "ZoneRedundant"
}

variable "database_name" {
  type    = string
  default = "appdb"
}

variable "aws_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "log_analytics_workspace_id" {
  type = string
}

variable "action_group_id" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
