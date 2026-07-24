output "cluster_name" {
  description = "Name of the EKS cluster. Used by scripts to build a kubeconfig with `aws eks update-kubeconfig`."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "region" {
  description = "AWS region the environment is deployed in."
  value       = var.region
}

output "ecr_repository_url" {
  description = "Registry URL of the application image repository. Images are pushed as `<url>:<40-char git SHA>`."
  value       = module.ecr.repository_url
}

output "ecr_cache_repository_url" {
  description = "Registry URL of the BuildKit cache repository, used as the `--cache-to`/`--cache-from` reference."
  value       = module.ecr.cache_repository_url
}

output "attachments_bucket" {
  description = "Name of the S3 attachments bucket. Passed to the app as the `AWS_BUCKET` environment variable."
  value       = module.storage.bucket_id
}

output "rds_address" {
  description = "DNS hostname of the RDS MySQL instance, without the port. The password lives only in Secrets Manager."
  value       = module.database.address
}

output "redis_address" {
  description = "DNS hostname of the Redis primary node. Requires a TLS connection with the AUTH token from Secrets Manager."
  value       = module.cache.primary_endpoint_address
}

output "irsa_role_arns" {
  description = "Map of IRSA role ARNs keyed by workload (alb_controller, external_secrets, cluster_autoscaler, app, fluent_bit, cloudwatch_exporter). Consumed by the Helm chart's serviceAccount annotations."
  value       = module.eks.irsa_role_arns
}

output "secret_names" {
  description = "Map of logical secret key to Secrets Manager secret name, consumed by the ExternalSecret manifests: app_key, smtp, database, redis."
  value = merge(
    module.secrets.secret_names,
    {
      database = module.database.credentials_secret_name
      redis    = module.cache.auth_token_secret_name
    },
  )
}

output "vpc_id" {
  description = "ID of the dev VPC."
  value       = module.network.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets hosting nodes, pods, RDS and ElastiCache."
  value       = module.network.private_subnet_ids
}

output "node_security_group_id" {
  description = "ID of the EKS worker node security group. Referenced when granting additional in-VPC access."
  value       = module.eks.node_security_group_id
}
