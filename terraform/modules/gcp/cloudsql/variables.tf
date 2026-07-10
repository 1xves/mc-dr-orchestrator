variable "instance_name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "network_id" {
  type = string
}

variable "private_services_connection" {
  type        = string
  description = "ID of the private services connection — used as depends_on"
}

variable "db_version" {
  type    = string
  default = "POSTGRES_15"
}

variable "tier" {
  type        = string
  default     = "db-f1-micro"
  description = "Cloud SQL machine tier"
}

variable "disk_size_gb" {
  type    = number
  default = 10
}

variable "high_availability" {
  type        = bool
  default     = false
  description = "Regional HA requires tier db-g1-small or higher"
}

variable "db_name" {
  type    = string
  default = "drapp"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "labels" {
  type    = map(string)
  default = {}
}
