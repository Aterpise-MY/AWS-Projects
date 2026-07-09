output "backfill_bucket" {
  description = "Backfill S3 bucket name."
  value       = aws_s3_bucket.backfill.id
}

output "backfill_bucket_arn" {
  description = "Backfill S3 bucket ARN."
  value       = aws_s3_bucket.backfill.arn
}

output "backfill_key" {
  description = "S3 key of the uploaded synthetic CSV."
  value       = var.backfill_key
}

output "glue_job_name" {
  description = "Glue backfill job name."
  value       = aws_glue_job.backfill.name
}

output "glue_connection_name" {
  description = "Glue NETWORK connection name."
  value       = aws_glue_connection.rds.name
}

output "glue_role_arn" {
  description = "Glue job IAM role ARN."
  value       = aws_iam_role.glue.arn
}

output "glue_sg_id" {
  description = "Glue security group ID."
  value       = aws_security_group.glue.id
}
