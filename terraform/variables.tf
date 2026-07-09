###############################################################################
# Root variables — AWS DR Orchestrator
###############################################################################

# ── General ───────────────────────────────────────────────────────────────────
variable "project_name" {
  type        = string
  default     = "mc-dr"
  description = "Short prefix used for all resource names"
}

variable "environment" {
  type    = string
  default = "production"
}

# ── AWS ───────────────────────────────────────────────────────────────────────
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "aws_availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "eks_node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "eks_node_desired_count" {
  type    = number
  default = 2
}

variable "eks_node_min_count" {
  type    = number
  default = 0
}

variable "eks_node_max_count" {
  type    = number
  default = 4
}

variable "kubernetes_version" {
  type    = string
  default = "1.32"
}

# ── Database ──────────────────────────────────────────────────────────────────
variable "db_master_password" {
  type      = string
  sensitive = true
}

# ── DNS / Routing ─────────────────────────────────────────────────────────────
variable "route53_zone_id" {
  type    = string
  default = ""
}

variable "domain_name" {
  type    = string
  default = ""
}

variable "primary_endpoint_fqdn" {
  type    = string
  default = "placeholder.example.com"
}

variable "aws_lb_dns_name" {
  type    = string
  default = ""
}

variable "aws_lb_zone_id" {
  type    = string
  default = ""
}

# ── Alerting ──────────────────────────────────────────────────────────────────
variable "alert_email" {
  type = string
}

variable "slack_webhook_url" {
  type      = string
  default   = ""
  sensitive = true
}
