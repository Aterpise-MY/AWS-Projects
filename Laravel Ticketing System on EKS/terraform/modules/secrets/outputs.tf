output "app_key_secret_arn" {
  description = "ARN of the Laravel APP_KEY secret. Included in the External Secrets IRSA policy scope."
  value       = aws_secretsmanager_secret.app_key.arn
}

output "app_key_secret_name" {
  description = "Name of the Laravel APP_KEY secret (`<name_prefix>/app-key`), referenced by the ExternalSecret remoteRef."
  value       = aws_secretsmanager_secret.app_key.name
}

output "smtp_secret_arn" {
  description = "ARN of the SMTP credentials secret. Included in the External Secrets IRSA policy scope."
  value       = aws_secretsmanager_secret.smtp.arn
}

output "smtp_secret_name" {
  description = "Name of the SMTP credentials secret (`<name_prefix>/smtp`), referenced by the ExternalSecret remoteRef."
  value       = aws_secretsmanager_secret.smtp.name
}

output "all_secret_arns" {
  description = "ARNs of every secret owned by this module. The dev root module concatenates this with the database and cache secret ARNs to build `eks.secret_arns`."
  value = [
    aws_secretsmanager_secret.app_key.arn,
    aws_secretsmanager_secret.smtp.arn,
  ]
}

output "secret_names" {
  description = "Map of logical secret key to Secrets Manager secret name for the secrets owned by this module."
  value = {
    app_key = aws_secretsmanager_secret.app_key.name
    smtp    = aws_secretsmanager_secret.smtp.name
  }
}
