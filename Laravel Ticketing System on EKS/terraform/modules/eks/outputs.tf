output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority bundle for the cluster, used to build a kubeconfig."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster, used as the trust anchor for IRSA."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC identity provider registered for the cluster."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "cluster_security_group_id" {
  description = "ID of the EKS-managed cluster security group that fronts the control plane ENIs."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_security_group_id" {
  description = "ID of the worker node security group. Referenced by the RDS and ElastiCache ingress rules."
  value       = aws_security_group.node.id
}

output "system_node_role_arn" {
  description = "IAM role ARN of the system node group. Granted pull access on the ECR repositories."
  value       = aws_iam_role.node["system"].arn
}

output "app_node_role_arn" {
  description = "IAM role ARN of the application node group. Granted pull access on the ECR repositories."
  value       = aws_iam_role.node["app"].arn
}

output "irsa_role_arns" {
  description = "Map of IRSA role ARNs keyed by workload: alb_controller, external_secrets, cluster_autoscaler, app, fluent_bit, cloudwatch_exporter. Consumed by the Helm chart's serviceAccount annotations."
  value       = { for key in local.exported_irsa_keys : key => aws_iam_role.irsa[key].arn }
}

output "ebs_csi_irsa_role_arn" {
  description = "IRSA role ARN used by the aws-ebs-csi-driver add-on. Wired to the add-on inside this module; exposed for auditing only."
  value       = aws_iam_role.irsa["ebs_csi"].arn
}

output "system_node_group_name" {
  description = "Name of the system managed node group."
  value       = aws_eks_node_group.system.node_group_name
}

output "app_node_group_name" {
  description = "Name of the application managed node group."
  value       = aws_eks_node_group.app.node_group_name
}

output "app_autoscaling_group_name" {
  description = "Name of the Auto Scaling group backing the application node group. Carries the Cluster Autoscaler discovery tags."
  value       = aws_eks_node_group.app.resources[0].autoscaling_groups[0].name
}

output "cluster_log_group_name" {
  description = "CloudWatch log group holding the control plane api and audit logs."
  value       = aws_cloudwatch_log_group.cluster.name
}
