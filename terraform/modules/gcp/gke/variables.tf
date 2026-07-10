variable "cluster_name" {
  type = string
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "zone" {
  type        = string
  default     = "us-central1-a"
  description = "Single zone for zonal cluster — avoids $0.10/hr regional management fee"
}

variable "network_name" {
  type = string
}

variable "subnet_name" {
  type = string
}

variable "pods_range_name" {
  type = string
}

variable "services_range_name" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.32"
}

variable "node_machine_type" {
  type    = string
  default = "e2-standard-2"
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

variable "labels" {
  type    = map(string)
  default = {}
}
