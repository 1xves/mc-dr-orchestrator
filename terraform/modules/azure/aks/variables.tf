variable "cluster_name" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "environment" {
  type    = string
  default = "dr-standby"
}

variable "kubernetes_version" {
  type    = string
  default = "1.29"
}

variable "aks_subnet_id" {
  type = string
}

variable "node_vm_size" {
  type    = string
  default = "Standard_DC4s_v3"
}

variable "standby_node_count" {
  type        = number
  default     = 0
  description = "0 = zero-cost standby; set to 3+ on failover"
}

variable "failover_node_count" {
  type        = number
  default     = 3
  description = "Target node count after failover"
}

variable "container_registry_id" {
  type    = string
  default = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
