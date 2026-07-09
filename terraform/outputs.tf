###############################################################################
# Root outputs
###############################################################################

# ── AWS ───────────────────────────────────────────────────────────────────────
output "aws_vpc_id"            { value = module.aws_vpc.vpc_id }
output "eks_cluster_name"      { value = module.aws_eks.cluster_name }
output "eks_cluster_endpoint"  { value = module.aws_eks.cluster_endpoint }
output "rds_endpoint"          { value = module.aws_rds.db_endpoint }
output "rds_secret_arn"        { value = module.aws_rds.secret_arn }
output "vpn_tunnel1_ip"        { value = module.aws_vpn.tunnel1_address }
output "vpn_tunnel2_ip"        { value = module.aws_vpn.tunnel2_address }
output "sns_alert_topic_arn"   { value = aws_sns_topic.alerts.arn }

# ── Azure ─────────────────────────────────────────────────────────────────────
output "azure_resource_group"     { value = module.azure_vnet.resource_group_name }
output "aks_cluster_name"         { value = module.azure_aks.cluster_name }
output "azure_postgresql_fqdn"    { value = module.azure_postgresql.server_fqdn }
output "azure_vpn_gateway_ip"     { value = module.azure_vpn.vpn_gateway_public_ip }

# ── Health Monitor Config (paste into .env) ───────────────────────────────────
output "health_monitor_env" {
  value = <<-EOT
    PRIMARY_URL=https://api.${var.domain_name}/healthz
    AWS_REGION=${var.aws_region}
    EKS_CLUSTER_NAME=${module.aws_eks.cluster_name}
    AZURE_RESOURCE_GROUP=${module.azure_vnet.resource_group_name}
    AZURE_AKS_CLUSTER=${module.azure_aks.cluster_name}
    AZURE_AKS_NODEPOOL=app
    AKS_FAILOVER_NODE_COUNT=${var.aks_failover_node_count}
    AZURE_PG_FQDN=${module.azure_postgresql.server_fqdn}
    ROUTE53_ZONE_ID=${var.route53_zone_id}
    SNS_TOPIC_ARN=${aws_sns_topic.alerts.arn}
  EOT
  sensitive = false
}
