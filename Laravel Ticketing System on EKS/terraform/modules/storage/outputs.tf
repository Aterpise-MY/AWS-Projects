output "bucket_id" {
  description = "Name of the attachments bucket. Passed to the application as the `AWS_BUCKET` environment variable."
  value       = aws_s3_bucket.attachments.id
}

output "bucket_arn" {
  description = "ARN of the attachments bucket. Consumed by the eks module as `attachments_bucket_arn` to scope the application IRSA policy."
  value       = aws_s3_bucket.attachments.arn
}

output "bucket_regional_domain_name" {
  description = "Region-specific domain name of the bucket, used when building pre-signed URLs."
  value       = aws_s3_bucket.attachments.bucket_regional_domain_name
}
