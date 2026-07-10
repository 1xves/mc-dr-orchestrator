variable "name" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "region" {
  type = string
}

variable "enable_nat" {
  type        = bool
  default     = false
  description = "Provision Cloud NAT. ~$32/month. Required for private nodes to reach internet."
}

variable "tags" {
  type    = map(string)
  default = {}
}
