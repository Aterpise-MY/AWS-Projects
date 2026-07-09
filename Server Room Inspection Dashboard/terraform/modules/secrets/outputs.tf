output "db_secret_arn" {
  description = "ARN of the RDS credentials secret (consumed by RDS/app later)."
  value       = aws_secretsmanager_secret.this["db"].arn
}

output "smtp_secret_arn" {
  description = "ARN of the SES/SMTP secret."
  value       = aws_secretsmanager_secret.this["smtp"].arn
}

output "ad_bind_secret_arn" {
  description = "ARN of the AD bind/service-account secret."
  value       = aws_secretsmanager_secret.this["ad_bind"].arn
}

output "secret_arns" {
  description = "Map of logical name -> secret ARN."
  value       = { for k, s in aws_secretsmanager_secret.this : k => s.arn }
}
