###############################################################################
# OUTPUTS
###############################################################################

output "vpc_id" {
  description = "ID of the project VPC that hosts the demo patch targets."
  value       = aws_vpc.main.id
}

output "subnet_id" {
  description = "ID of the public subnet the demo instances are launched into."
  value       = aws_subnet.public.id
}

output "instance_ids" {
  description = "Map of demo instance logical key => EC2 instance ID."
  value       = { for k, inst in aws_instance.demo : k => inst.id }
}

output "instance_patch_groups" {
  description = "Map of demo instance logical key => its Patch Group tag value."
  value       = { for k, def in local.instance_defs : k => def.patch_group }
}

output "instance_count_effective" {
  description = "Total number of demo instances created (equals var.instance_count)."
  value       = length(aws_instance.demo)
}

output "ssm_instance_role_arn" {
  description = "ARN of the IAM role attached to demo instances (AmazonSSMManagedInstanceCore)."
  value       = aws_iam_role.ssm_instance.arn
}

output "maintenance_window_role_arn" {
  description = "ARN of the SSM Maintenance Window service role."
  value       = aws_iam_role.maintenance_window.arn
}

output "patch_baseline_ids" {
  description = "Patch baseline IDs per OS."
  value = {
    al2023 = aws_ssm_patch_baseline.al2023.id
    ubuntu = aws_ssm_patch_baseline.ubuntu.id
  }
}

output "maintenance_window_ids" {
  description = "Maintenance window IDs per patch group."
  value = {
    al2023 = aws_ssm_maintenance_window.al2023.id
    ubuntu = aws_ssm_maintenance_window.ubuntu.id
  }
}

output "sns_topic_arn" {
  description = "ARN of the patch-alerts SNS topic."
  value       = aws_sns_topic.patch_alerts.arn
}

output "compliance_query_hint" {
  description = "CLI to check live patch compliance once instances have run at least one Install."
  value       = "aws ssm describe-instance-patch-states --instance-ids ${join(" ", [for inst in aws_instance.demo : inst.id])} --region ${var.region}"
}
