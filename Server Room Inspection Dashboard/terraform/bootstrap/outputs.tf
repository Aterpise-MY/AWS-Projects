output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform remote state."
  value       = aws_s3_bucket.tfstate.id
}

output "state_bucket_arn" {
  description = "ARN of the remote-state S3 bucket."
  value       = aws_s3_bucket.tfstate.arn
}

output "lock_table_name" {
  description = "Name of the DynamoDB state-lock table."
  value       = aws_dynamodb_table.tflock.id
}

output "region" {
  description = "Region the backend was created in."
  value       = var.region
}
