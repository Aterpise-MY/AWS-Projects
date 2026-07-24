###############################################################################
# Bootstrap — remote state backend for every other stack in this project.
#
# Run ONCE, with local state, before `terraform/dev/` is initialised:
#
#   terraform -chdir=terraform/bootstrap init
#   terraform -chdir=terraform/bootstrap apply
#
# Creates:
#   - KMS CMK + alias  alias/<name_prefix>-tfstate   (state encryption)
#   - S3 bucket        <name_prefix>-tfstate-<account_id>
#   - DynamoDB table   <name_prefix>-tflock          (state locking)
###############################################################################

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "ticketing"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = var.owner_email
      Repository  = "github.com/brendonang/ticketing-platform"
      Component   = "bootstrap"
      # No AutoDelete tag here on purpose: the state backend must outlive the
      # workloads it tracks. Sweeper automation keyed on AutoDelete=true would
      # otherwise delete the bucket holding the state for everything else.
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "${var.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}"
  lock_table_name   = "${var.name_prefix}-tflock"
}

###############################################################################
# KMS — customer-managed key used for SSE-KMS on the state bucket
###############################################################################

resource "aws_kms_key" "tfstate" {
  description             = "Encrypts Terraform state objects for ${var.name_prefix}"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true

  tags = {
    Name = "${var.name_prefix}-tfstate"
  }
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/${var.name_prefix}-tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

###############################################################################
# S3 — the state bucket
###############################################################################

resource "aws_s3_bucket" "tfstate" {
  bucket        = local.state_bucket_name
  force_destroy = var.force_destroy_state_bucket

  tags = {
    Name = local.state_bucket_name
  }
}

# Versioning is non-negotiable: it is the only recovery path from a corrupted
# or partially-written state file.
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
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    # Cuts KMS API calls (and cost) for the many small GETs Terraform issues.
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

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Deny any request that is not TLS-protected. State files are the single most
# sensitive object in the account.
resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  policy = data.aws_iam_policy_document.tfstate.json

  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

data "aws_iam_policy_document" "tfstate" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# Expire noncurrent state versions so the bucket does not grow without bound,
# while still keeping a 90-day rollback window.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.tfstate]
}

###############################################################################
# DynamoDB — state lock table
###############################################################################

resource "aws_dynamodb_table" "tflock" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name = local.lock_table_name
  }
}
