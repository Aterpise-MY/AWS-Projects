output "nlb_dns_name" {
  description = "Public DNS name of the Network Load Balancer. Use this to access the application: http://<nlb_dns_name>"
  value       = aws_lb.web.dns_name
}

output "nlb_arn" {
  description = "ARN of the Network Load Balancer."
  value       = aws_lb.web.arn
}

output "asg_name" {
  description = "Name of the Auto Scaling Group."
  value       = aws_autoscaling_group.web.name
}

output "asg_arn" {
  description = "ARN of the Auto Scaling Group."
  value       = aws_autoscaling_group.web.arn
}

output "launch_template_id" {
  description = "ID of the EC2 Launch Template."
  value       = aws_launch_template.web.id
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (NLB placement)."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (EC2 instance placement)."
  value       = module.vpc.private_subnets
}

output "ec2_security_group_id" {
  description = "ID of the security group attached to EC2 instances."
  value       = aws_security_group.ec2.id
}

output "iam_role_arn" {
  description = "ARN of the IAM role attached to EC2 instances."
  value       = aws_iam_role.ec2.arn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic used for CloudWatch alarm notifications."
  value       = aws_sns_topic.alarms.arn
}

output "target_group_arn" {
  description = "ARN of the NLB Target Group."
  value       = aws_lb_target_group.web.arn
}

output "waf_web_acl_arn" {
  description = "ARN of the WAFv2 Web ACL. Not associated with the NLB (NLB is Layer 4; WAFv2 requires Layer 7). Associate with an ALB ARN if you add an ALB in front of the NLB."
  value       = aws_wafv2_web_acl.main.arn
}
