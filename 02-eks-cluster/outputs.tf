output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority" {
  description = "Base64 encoded certificate authority data for the EKS cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for the EKS cluster, used by IRSA"
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider, used when creating IRSA roles in other modules"
  value       = aws_iam_openid_connect_provider.main.arn
}

output "node_role_arn" {
  description = "ARN of the IAM role attached to worker nodes"
  value       = aws_iam_role.node.arn
}

output "cluster_security_group_id" {
  description = "ID of the security group automatically created by EKS for the cluster"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "karpenter_node_role_arn" {
  description = "ARN of the IAM role that Karpenter assigns to nodes it provisions"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_irsa_role_arn" {
  description = "ARN of the IRSA role that Karpenter itself uses to call AWS APIs"
  value       = aws_iam_role.karpenter_irsa.arn
}

output "karpenter_instance_profile_name" {
  description = "Name of the instance profile that Karpenter assigns to nodes it provisions"
  value       = aws_iam_instance_profile.karpenter_node.name
}