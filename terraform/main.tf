###############################################################################
# Root Terraform configuration — AWS DR Orchestrator
###############################################################################

locals {
  common_tags = {
    Project     = "mc-dr"
    ManagedBy   = "terraform"
    Environment = var.environment
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "aws_vpc" {
  source = "./modules/aws/vpc"

  name                = "${var.project_name}-primary"
  vpc_cidr            = var.aws_vpc_cidr
  cluster_name        = "${var.project_name}-eks"
  availability_zones  = var.aws_availability_zones
  single_nat_gateway  = true
  tags                = local.common_tags
}

# ── EKS ───────────────────────────────────────────────────────────────────────
module "aws_eks" {
  source = "./modules/aws/eks"

  cluster_name        = "${var.project_name}-eks"
  vpc_id              = module.aws_vpc.vpc_id
  public_subnet_ids   = module.aws_vpc.public_subnet_ids
  private_subnet_ids  = module.aws_vpc.private_subnet_ids
  node_instance_types = var.eks_node_instance_types
  node_desired_count  = var.eks_node_desired_count
  node_min_count      = var.eks_node_min_count
  node_max_count      = var.eks_node_max_count
  kubernetes_version  = var.kubernetes_version
  environment         = var.environment
  tags                = local.common_tags
}

# ── RDS ───────────────────────────────────────────────────────────────────────
module "aws_rds" {
  source = "./modules/aws/rds"

  identifier          = "${var.project_name}-primary-pg"
  vpc_id              = module.aws_vpc.vpc_id
  subnet_ids          = module.aws_vpc.database_subnet_ids
  allowed_cidr_blocks = [var.aws_vpc_cidr]
  master_password     = var.db_master_password
  multi_az            = false
  alarm_sns_arn       = aws_sns_topic.alerts.arn
  tags                = local.common_tags
}

# ── SNS Alerts ────────────────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name              = "${var.project_name}-dr-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.common_tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "alerts_slack_lambda" {
  count     = var.slack_webhook_url != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.slack_notifier[0].arn
}

# ── Slack Lambda (optional) ───────────────────────────────────────────────────
resource "aws_lambda_function" "slack_notifier" {
  count         = var.slack_webhook_url != "" ? 1 : 0
  function_name = "${var.project_name}-slack-notifier"
  role          = aws_iam_role.lambda_basic[0].arn
  handler       = "slack_notifier.handler"
  runtime       = "python3.12"
  filename      = "${path.module}/../scripts/slack_notifier.zip"

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }

  tags = local.common_tags
}

resource "aws_iam_role" "lambda_basic" {
  count = var.slack_webhook_url != "" ? 1 : 0
  name  = "${var.project_name}-lambda-basic"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  count      = var.slack_webhook_url != "" ? 1 : 0
  role       = aws_iam_role.lambda_basic[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ── Route53 Health Check ──────────────────────────────────────────────────────
resource "aws_route53_health_check" "primary" {
  fqdn              = var.primary_endpoint_fqdn
  port              = 443
  type              = "HTTPS"
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 30
  tags              = merge(local.common_tags, { Name = "${var.project_name}-primary-hc" })
}

resource "aws_route53_record" "primary" {
  count   = var.aws_lb_dns_name != "" && var.aws_lb_zone_id != "" && var.route53_zone_id != "" ? 1 : 0
  zone_id = var.route53_zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier  = "primary"
  health_check_id = aws_route53_health_check.primary.id

  alias {
    name                   = var.aws_lb_dns_name
    zone_id                = var.aws_lb_zone_id
    evaluate_target_health = true
  }
}
