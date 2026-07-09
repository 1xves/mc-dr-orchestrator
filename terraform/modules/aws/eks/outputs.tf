output "cluster_id"               { value = aws_eks_cluster.main.id }
output "cluster_name"             { value = aws_eks_cluster.main.name }
output "cluster_endpoint"         { value = aws_eks_cluster.main.endpoint }
output "cluster_ca"               { value = aws_eks_cluster.main.certificate_authority[0].data }
output "cluster_oidc_issuer"      { value = aws_eks_cluster.main.identity[0].oidc[0].issuer }
output "oidc_provider_arn"        { value = aws_iam_openid_connect_provider.eks.arn }
output "node_group_arn"           { value = aws_eks_node_group.main.arn }
output "cluster_security_group_id"{ value = aws_security_group.cluster.id }
