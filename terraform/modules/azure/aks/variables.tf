variable "cluster_name" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "resource_group_name" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.32"
}

variable "node_vm_size" {
  type    = string
  default = "Standard_D2as_v7" # keep in sync with root aks_node_vm_size; B2s is location-blocked in eastus2
}

variable "node_min_count" {
  type    = number
  default = 0
}

variable "node_max_count" {
  type    = number
  default = 3
}

variable "node_initial_count" {
  type    = number
  default = 1
}

variable "tags" {
  type    = map(string)
  default = {}
}
