# The master credential is deliberately never exposed as an output. It exists
# only in Terraform state and in Secrets Manager; consumers read it through the
# External Secrets Operator using credentials_secret_name. This file is grepped
# in CI to prove no plaintext credential ever reaches a module output.

output "endpoint" {
  description = "Connection endpoint in host:port form."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "DNS hostname of the RDS instance, without the port."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "TCP port the MySQL instance listens on."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Name of the initial schema created on the instance."
  value       = aws_db_instance.this.db_name
}

output "username" {
  description = "Master username. The matching credential is available only from Secrets Manager."
  value       = aws_db_instance.this.username
}

output "security_group_id" {
  description = "ID of the security group attached to the RDS instance."
  value       = aws_security_group.this.id
}

output "credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the connection JSON. Added to the External Secrets IRSA policy by the root module."
  value       = aws_secretsmanager_secret.credentials.arn
}

output "credentials_secret_name" {
  description = "Name of the Secrets Manager secret holding the connection JSON. Referenced by the ExternalSecret manifest in the Helm chart."
  value       = aws_secretsmanager_secret.credentials.name
}

output "instance_identifier" {
  description = "RDS DB instance identifier."
  value       = aws_db_instance.this.identifier
}

output "parameter_group_name" {
  description = "Name of the DB parameter group applied to the instance."
  value       = aws_db_parameter_group.this.name
}
