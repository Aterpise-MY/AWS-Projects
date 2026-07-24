output "state_bucket_name" {
  description = "Name of the S3 bucket holding remote Terraform state. Use as `bucket` in the dev backend configuration."
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table_name" {
  description = "Name of the DynamoDB table used for Terraform state locking. Use as `dynamodb_table` in the dev backend configuration."
  value       = aws_dynamodb_table.tflock.name
}

output "kms_key_arn" {
  description = "ARN of the customer-managed KMS key that encrypts state objects. Use as `kms_key_id` in the dev backend configuration."
  value       = aws_kms_key.tfstate.arn
}

output "kms_key_alias" {
  description = "Alias of the state-encryption KMS key."
  value       = aws_kms_alias.tfstate.name
}

output "region" {
  description = "Region the state backend resources were created in."
  value       = var.aws_region
}
