variable "name" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "cluster_name" {
  type = string
}

variable "availability_zones" {
  type = list(string)
}

variable "single_nat_gateway" {
  type        = bool
  default     = true
  description = "Use one NAT gateway for all AZs (dev/cost saving). Set false for prod."
}

variable "tags" {
  type    = map(string)
  default = {}
}
