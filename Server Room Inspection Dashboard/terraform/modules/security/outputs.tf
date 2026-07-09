output "alb_sg_id" {
  description = "ALB security group ID."
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "App/Fargate security group ID."
  value       = aws_security_group.app.id
}

output "data_sg_id" {
  description = "Data-tier (RDS) security group ID (consumed by RDS later)."
  value       = aws_security_group.data.id
}
