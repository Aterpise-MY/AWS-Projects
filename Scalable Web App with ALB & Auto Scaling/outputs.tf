output "https_url" {
  description = "HTTPS URL of the application. Plain HTTP requests to the same hostname are redirected here."
  value       = "https://${var.domain_name}"
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer (no scheme). The Cloudflare CNAME for domain_name points here."
  value       = aws_lb.web.dns_name
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.web.arn
}

output "certificate_arn" {
  description = "ARN of the ACM certificate attached to the HTTPS listener."
  value       = aws_acm_certificate.web.arn
}

output "target_group_arn" {
  description = "ARN of the ALB Target Group."
  value       = aws_lb_target_group.web.arn
}

output "asg_name" {
  description = "Name of the Auto Scaling Group."
  value       = aws_autoscaling_group.web.name
}

output "launch_template_id" {
  description = "ID of the EC2 Launch Template."
  value       = aws_launch_template.web.id
}

output "launch_template_latest_version" {
  description = "Latest version number of the EC2 Launch Template."
  value       = aws_launch_template.web.latest_version
}

output "alb_security_group_id" {
  description = "ID of the load balancer security group (80 and 443 from the internet)."
  value       = aws_security_group.alb.id
}

output "ec2_security_group_id" {
  description = "ID of the instance security group (80 from the load balancer security group only)."
  value       = aws_security_group.ec2.id
}

output "db_security_group_id" {
  description = "ID of the database security group (5432 from the instance security group only)."
  value       = aws_security_group.db.id
}

output "ami_id" {
  description = "Amazon Linux 2023 AMI ID resolved at plan time."
  value       = data.aws_ssm_parameter.al2023_ami.insecure_value
}

output "db_instance_identifier" {
  description = "Identifier of the RDS DB instance."
  value       = aws_db_instance.web.identifier
}

output "db_endpoint" {
  description = "Connection endpoint of the RDS DB instance, as host:port. Reachable from the instance security group only."
  value       = aws_db_instance.web.endpoint
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret that RDS manages for the master user. The ARN only; the secret value is never an output."
  value       = aws_db_instance.web.master_user_secret[0].secret_arn
}
