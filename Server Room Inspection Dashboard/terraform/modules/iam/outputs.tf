output "ecs_task_execution_role_arn" {
  description = "ECS task execution role ARN."
  value       = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_execution_role_name" {
  description = "ECS task execution role name (for later policy attachments)."
  value       = aws_iam_role.ecs_task_execution.name
}

output "ecs_task_role_arn" {
  description = "ECS task (runtime) role ARN."
  value       = aws_iam_role.ecs_task.arn
}

output "ecs_task_role_name" {
  description = "ECS task role name (for later policy attachments)."
  value       = aws_iam_role.ecs_task.name
}

output "lambda_execution_role_arn" {
  description = "Lambda execution role ARN."
  value       = aws_iam_role.lambda_execution.arn
}

output "lambda_execution_role_name" {
  description = "Lambda execution role name (for later policy attachments)."
  value       = aws_iam_role.lambda_execution.name
}
