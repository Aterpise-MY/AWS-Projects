# The AUTH token is intentionally absent from this file. It exists only in
# Terraform state and in Secrets Manager; consumers read it through the External
# Secrets Operator using auth_token_secret_name.

output "primary_endpoint_address" {
  description = "DNS hostname of the Redis primary node. Requires a TLS connection."
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "port" {
  description = "TCP port the Redis primary listens on."
  value       = aws_elasticache_replication_group.this.port
}

output "security_group_id" {
  description = "ID of the security group attached to the replication group."
  value       = aws_security_group.this.id
}

output "auth_token_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the AUTH token and connection JSON. Added to the External Secrets IRSA policy by the root module."
  value       = aws_secretsmanager_secret.auth_token.arn
}

output "auth_token_secret_name" {
  description = "Name of the Secrets Manager secret holding the AUTH token and connection JSON. Referenced by the ExternalSecret manifest in the Helm chart."
  value       = aws_secretsmanager_secret.auth_token.name
}

output "replication_group_id" {
  description = "ElastiCache replication group identifier."
  value       = aws_elasticache_replication_group.this.replication_group_id
}

output "redis_database_indexes" {
  description = "Logical Redis database index assignment: 0 cache, 1 sessions, 2 queue. Consumed by the Helm chart so the application and this module cannot drift apart."
  value = {
    cache    = 0
    sessions = 1
    queue    = 2
  }
}
