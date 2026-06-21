output "app_runner_service_arn" {
  description = "ARN of the App Runner service"
  value       = aws_apprunner_service.main.arn
}

output "app_runner_service_url" {
  description = "Public URL of the App Runner service"
  value       = aws_apprunner_service.main.service_url
}

output "app_runner_service_status" {
  description = "Status of the App Runner service"
  value       = aws_apprunner_service.main.status
}

output "ecr_repository_url" {
  description = "URL of the ECR repository"
  value       = aws_ecr_repository.app_runner_repo.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the ECR repository"
  value       = aws_ecr_repository.app_runner_repo.arn
}

output "ecr_registry_id" {
  description = "Registry ID of the ECR repository"
  value       = aws_ecr_repository.app_runner_repo.registry_id
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for App Runner logs"
  value       = aws_cloudwatch_log_group.app_runner_logs.name
}

output "cloudwatch_log_group_arn" {
  description = "CloudWatch log group ARN"
  value       = aws_cloudwatch_log_group.app_runner_logs.arn
}

output "app_runner_service_role_arn" {
  description = "ARN of the App Runner service IAM role"
  value       = aws_iam_role.app_runner_service_role.arn
}

output "app_runner_instance_role_arn" {
  description = "ARN of the App Runner instance IAM role"
  value       = aws_iam_role.app_runner_instance_role.arn
}

output "auto_scaling_configuration_arn" {
  description = "ARN of the auto scaling configuration"
  value       = aws_apprunner_auto_scaling_configuration_version.main.arn
}

output "auto_scaling_configuration_revision" {
  description = "Revision number of the auto scaling configuration"
  value       = aws_apprunner_auto_scaling_configuration_version.main.auto_scaling_configuration_revision
}

output "cpu_alarm_arn" {
  description = "ARN of the CPU utilization alarm"
  value       = aws_cloudwatch_metric_alarm.cpu_high.arn
}

output "memory_alarm_arn" {
  description = "ARN of the memory utilization alarm"
  value       = aws_cloudwatch_metric_alarm.memory_high.arn
}

output "deployment_alarm_arn" {
  description = "ARN of the deployment failure alarm"
  value       = aws_cloudwatch_metric_alarm.deployment_failed.arn
}
