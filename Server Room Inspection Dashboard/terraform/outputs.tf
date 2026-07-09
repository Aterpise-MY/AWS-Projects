# ===========================================================================
# Root outputs — the contract later phases consume.
# ===========================================================================

# --- Networking ------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID."
  value       = module.networking.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = module.networking.vpc_cidr
}

output "igw_id" {
  description = "Internet Gateway ID."
  value       = module.networking.igw_id
}

output "nat_gateway_ids" {
  description = "NAT Gateway ID(s)."
  value       = module.networking.nat_gateway_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = module.networking.public_subnet_ids
}

output "app_subnet_ids" {
  description = "Private-app subnet IDs (Fargate/Lambda)."
  value       = module.networking.app_subnet_ids
}

output "data_subnet_ids" {
  description = "Private-data subnet IDs (RDS — Phase 1)."
  value       = module.networking.data_subnet_ids
}

output "public_route_table_id" {
  description = "Public route table ID."
  value       = module.networking.public_route_table_id
}

output "private_route_table_id" {
  description = "Private route table ID."
  value       = module.networking.private_route_table_id
}

# --- Security groups -------------------------------------------------------
output "alb_sg_id" {
  description = "ALB security group ID."
  value       = module.security.alb_sg_id
}

output "app_sg_id" {
  description = "App/Fargate security group ID."
  value       = module.security.app_sg_id
}

output "data_sg_id" {
  description = "Data-tier (RDS) security group ID — Phase 1."
  value       = module.security.data_sg_id
}

# --- KMS -------------------------------------------------------------------
output "kms_key_id" {
  description = "Customer-managed KMS key ID."
  value       = module.kms.key_id
}

output "kms_key_arn" {
  description = "Customer-managed KMS key ARN (reused by RDS/S3/Secrets)."
  value       = module.kms.key_arn
}

output "kms_alias_name" {
  description = "KMS alias."
  value       = module.kms.alias_name
}

# --- IAM -------------------------------------------------------------------
output "ecs_task_execution_role_arn" {
  description = "ECS task execution role ARN."
  value       = module.iam.ecs_task_execution_role_arn
}

output "ecs_task_role_arn" {
  description = "ECS task (runtime) role ARN."
  value       = module.iam.ecs_task_role_arn
}

output "lambda_execution_role_arn" {
  description = "Lambda execution role ARN."
  value       = module.iam.lambda_execution_role_arn
}

# --- Secrets ---------------------------------------------------------------
output "db_secret_arn" {
  description = "RDS credentials secret ARN — Phase 1."
  value       = module.secrets.db_secret_arn
}

output "smtp_secret_arn" {
  description = "SES/SMTP secret ARN."
  value       = module.secrets.smtp_secret_arn
}

output "ad_bind_secret_arn" {
  description = "AD bind/service-account secret ARN."
  value       = module.secrets.ad_bind_secret_arn
}

# --- Convenience -----------------------------------------------------------
output "name_prefix" {
  description = "Resource name prefix."
  value       = local.name_prefix
}

output "region" {
  description = "Deployment region."
  value       = var.region
}

# ===========================================================================
# Phase 1 — Database outputs (consumed by Phase 2 Ingestion).
# ===========================================================================
output "db_instance_id" {
  description = "RDS instance identifier."
  value       = module.database.db_instance_id
}

output "db_endpoint" {
  description = "RDS endpoint host (private, non-public)."
  value       = module.database.db_address
}

output "db_port" {
  description = "RDS port."
  value       = module.database.db_port
}

output "db_name" {
  description = "Application database name."
  value       = module.database.db_name
}

output "db_parameter_group" {
  description = "DB parameter group name."
  value       = module.database.parameter_group_name
}

output "db_subnet_group" {
  description = "DB subnet group name."
  value       = module.database.subnet_group_name
}

output "app_username" {
  description = "Least-privilege app login role (password stored in db secret)."
  value       = module.database.app_username
}

# ===========================================================================
# Phase 2 — Ingestion (migration/glue) outputs
# ===========================================================================
output "migration_lambda_name" {
  description = "Migration/verification Lambda (reusable by later phases)."
  value       = module.migration.function_name
}

output "backfill_bucket" {
  description = "Synthetic-backfill S3 bucket."
  value       = module.glue.backfill_bucket
}

output "glue_backfill_job" {
  description = "Glue backfill job name."
  value       = module.glue.glue_job_name
}

output "glue_connection_name" {
  description = "Glue NETWORK connection name."
  value       = module.glue.glue_connection_name
}

output "glue_role_arn" {
  description = "Glue job IAM role ARN."
  value       = module.glue.glue_role_arn
}

# ===========================================================================
# Phase 3 — Dashboard compute outputs
# ===========================================================================
output "dashboard_url" {
  description = "Clickable dashboard URL (overview page)."
  value       = module.compute.dashboard_url
}

output "alb_dns_name" {
  description = "Public DNS name of the dashboard ALB."
  value       = module.compute.alb_dns_name
}

output "ecr_repository_url" {
  description = "ECR repository URL to push the dashboard image to."
  value       = module.compute.ecr_repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = module.compute.ecs_cluster_name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = module.compute.ecs_service_name
}

# ===========================================================================
# Phase 4 — Authentication (Cognito) outputs
# ===========================================================================
output "cognito_user_pool_id" {
  description = "Cognito user pool ID."
  value       = module.cognito.user_pool_id
}

output "cognito_hosted_ui_url" {
  description = "Cognito hosted-UI base URL."
  value       = module.cognito.hosted_ui_url
}

# ===========================================================================
# Phase 6 — Observability outputs
# ===========================================================================
output "sns_alarms_topic_arn" {
  description = "SNS topic ARN alarms publish to."
  value       = module.observability.sns_topic_arn
}

output "cloudwatch_dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = module.observability.dashboard_name
}
