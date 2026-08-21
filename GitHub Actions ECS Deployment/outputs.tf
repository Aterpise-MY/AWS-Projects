###############################################################################
# OUTPUTS
###############################################################################

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer. Browse http://<this> to reach the app."
  value       = aws_lb.main.dns_name
}

output "ecr_repository_url" {
  description = "ECR repository URI. Set this (or its name) as the GitHub Actions ECR_REPOSITORY_NAME secret target."
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name — use as the ECS_CLUSTER GitHub Actions secret."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "ECS service name — use as the ECS_SERVICE GitHub Actions secret."
  value       = aws_ecs_service.app.name
}

output "task_definition_family" {
  description = "Task definition family — matches the `family` in task-definition.json."
  value       = aws_ecs_task_definition.app.family
}

output "task_execution_role_arn" {
  description = "IAM role ECS uses to pull images and write logs."
  value       = aws_iam_role.task_execution.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch Logs group streaming container stdout/stderr."
  value       = aws_cloudwatch_log_group.app.name
}

output "vpc_id" {
  description = "ID of the project VPC."
  value       = aws_vpc.main.id
}
