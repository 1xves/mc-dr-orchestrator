variable "cluster_name" {
  type = string
}

variable "environment" {
  type    = string
  default = "production"
}

variable "kubernetes_version" {
  type    = string
  default = "1.29"
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "node_instance_types" {
  type    = list(string)
  default = ["m5.xlarge"]
}

variable "node_desired_count" {
  type    = number
  default = 3
}

variable "node_min_count" {
  type    = number
  default = 2
}

variable "node_max_count" {
  type    = number
  default = 10
}

variable "public_endpoint" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
