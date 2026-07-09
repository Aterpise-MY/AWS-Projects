output "alb_dns_name" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.this.dns_name
}

output "alb_arn" {
  description = "ALB ARN."
  value       = aws_lb.this.arn
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix (for CloudWatch AWS/ApplicationELB metrics)."
  value       = aws_lb.this.arn_suffix
}

output "alb_listener_arn" {
  description = "HTTP listener ARN (consumed by the Phase 4 Cognito auth rule)."
  value       = aws_lb_listener.http.arn
}

output "ecr_repository_url" {
  description = "ECR repository URL to push the dashboard image to."
  value       = aws_ecr_repository.this.repository_url
}

output "ecs_cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "target_group_arn" {
  description = "Target group ARN."
  value       = aws_lb_target_group.this.arn
}

output "target_group_arn_suffix" {
  description = "Target group ARN suffix (for CloudWatch UnHealthyHostCount)."
  value       = aws_lb_target_group.this.arn_suffix
}

output "dashboard_url" {
  description = "Clickable dashboard URL (overview page)."
  value       = "http://${aws_lb.this.dns_name}/overview"
}

output "log_group_name" {
  description = "CloudWatch log group name for the dashboard container."
  value       = aws_cloudwatch_log_group.this.name
}
