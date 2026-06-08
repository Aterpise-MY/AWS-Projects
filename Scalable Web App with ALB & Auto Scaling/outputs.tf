output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer. Point your domain's CNAME here."
  value       = "http://${aws_lb.web.dns_name}"
}

output "alb_arn" {
  description = "ARN of the Application Load Balancer."
  value       = aws_lb.web.arn
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

output "security_group_id" {
  description = "ID of the Security Group attached to the ALB and EC2 instances."
  value       = aws_security_group.web.id
}

output "ami_id" {
  description = "Amazon Linux 2 AMI ID resolved at plan time."
  value       = data.aws_ami.amazon_linux_2.id
}
