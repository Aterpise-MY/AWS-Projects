# ---------------------------------------------------------------------------
# Bootstrap — Remote State Backend
# ---------------------------------------------------------------------------
# This configuration uses LOCAL state to provision the remote-state backend
# (an S3 bucket + a DynamoDB lock table) that the MAIN configuration then
# consumes via its `backend "s3"` block.
#
# Run this ONCE, before the main config. Its own state (terraform.tfstate)
# lives locally in this folder and is git-ignored.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "mcf-srid"
      Environment = "prod"
      ManagedBy   = "Terraform"
      Owner       = "MCF-Facilities"
      CostCenter  = "MCF-IT-Ops"
      Component   = "tf-state-backend"
    }
  }
}

# ---------------------------------------------------------------------------
# S3 bucket — Terraform remote state
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  # Full teardown: allow destroy and empty all object versions first.
  force_destroy = true

  tags = {
    Name = var.state_bucket_name
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      # SSE-S3 (AES256) is used here to avoid a chicken-and-egg dependency on
      # the customer-managed KMS key, which is created by the MAIN config.
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enforce TLS-only access to the state bucket.
resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.tfstate.arn,
          "${aws_s3_bucket.tfstate.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# DynamoDB table — Terraform state lock
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "tflock" {
  name         = var.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name = var.lock_table_name
  }
}
