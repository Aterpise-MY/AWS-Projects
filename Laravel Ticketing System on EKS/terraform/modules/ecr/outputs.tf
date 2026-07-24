output "repository_url" {
  description = "Registry URL of the application repository, e.g. `<account>.dkr.ecr.<region>.amazonaws.com/ticketing/app`. Images are referenced as `<url>:<40-char git SHA>`."
  value       = aws_ecr_repository.app.repository_url
}

output "repository_arn" {
  description = "ARN of the application repository."
  value       = aws_ecr_repository.app.arn
}

output "repository_name" {
  description = "Name of the application repository, as used by `aws ecr` CLI calls."
  value       = aws_ecr_repository.app.name
}

output "cache_repository_url" {
  description = "Registry URL of the BuildKit cache repository, used as the `--cache-to`/`--cache-from` registry reference."
  value       = aws_ecr_repository.cache.repository_url
}

output "cache_repository_arn" {
  description = "ARN of the BuildKit cache repository."
  value       = aws_ecr_repository.cache.arn
}

output "cache_repository_name" {
  description = "Name of the BuildKit cache repository."
  value       = aws_ecr_repository.cache.name
}

output "registry_id" {
  description = "AWS account ID that owns the repositories."
  value       = aws_ecr_repository.app.registry_id
}
