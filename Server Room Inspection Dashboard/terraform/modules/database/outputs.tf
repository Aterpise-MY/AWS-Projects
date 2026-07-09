output "db_instance_id" {
  description = "RDS instance identifier."
  value       = aws_db_instance.this.identifier
}

output "db_instance_arn" {
  description = "RDS instance ARN."
  value       = aws_db_instance.this.arn
}

output "db_address" {
  description = "RDS endpoint host (address only)."
  value       = aws_db_instance.this.address
}

output "db_port" {
  description = "RDS port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Application database name."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "RDS master username."
  value       = var.master_username
}

output "app_username" {
  description = "Application login-role name."
  value       = var.app_username
}

output "parameter_group_name" {
  description = "DB parameter group name."
  value       = aws_db_parameter_group.this.name
}

output "subnet_group_name" {
  description = "DB subnet group name."
  value       = aws_db_subnet_group.this.name
}

# --- Sensitive: consumed by the secrets module to populate the db secret. ---
output "db_connection" {
  description = "Full connection payload for the credentials secret (sensitive)."
  sensitive   = true
  value = {
    engine       = "postgres"
    host         = aws_db_instance.this.address
    port         = aws_db_instance.this.port
    dbname       = aws_db_instance.this.db_name
    username     = var.master_username
    password     = random_password.master.result
    app_username = var.app_username
    app_password = random_password.app.result
  }
}
