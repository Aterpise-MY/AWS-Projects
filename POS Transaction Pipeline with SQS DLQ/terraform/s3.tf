###############################################################################
# S3 — poison message archive
#
# Scenario §8 Phase 5 requires permanent/poison messages to be archived before
# they are deleted from a DLQ, and runbook Path B ("archive -> notify -> purge")
# is built around this bucket. Deleting a DLQ message is irreversible: the
# message body is the only evidence of which store, terminal and firmware
# version produced the bad transaction, and Store Ops needs that to scope a
# firmware upgrade. Archiving is what makes "delete" a safe operation rather
# than a second silent loss.
#
# Access model: this bucket is written by a HUMAN OPERATOR using their own
# credentials while following the runbook. The consumer Lambda roles are
# deliberately NOT granted any access to it — a consumer has no reason to write
# here, and granting it would let a compromised or buggy function tamper with
# the evidence trail it is supposed to preserve.
###############################################################################

resource "aws_s3_bucket" "dlq_archive" {
  # S3 bucket names are globally unique across all AWS accounts, so the account
  # ID is appended to keep this deployable in any account without collision.
  # `name_prefix` is validated as lowercase in variables.tf, which S3 requires.
  bucket = "${var.name_prefix}-dlq-archive-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.name_prefix}-dlq-archive-${data.aws_caller_identity.current.account_id}"
    Role = "poison-message-archive"
  }
}

# Versioning protects the evidence trail from an operator overwriting an
# existing archive object. The runbook writes to a per-incident prefix, but a
# repeated Path B for the same service on the same day would otherwise
# overwrite `archive.ndjson` in place.
resource "aws_s3_bucket_versioning" "dlq_archive" {
  bucket = aws_s3_bucket.dlq_archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES256). Archived bodies contain member IDs and purchase detail, so
# they are encrypted at rest. Consistent with the SSE-SQS choice on the queues:
# no customer managed KMS key, avoiding the ~USD 1/month per-key charge (§11).
resource "aws_s3_bucket_server_side_encryption_configuration" "dlq_archive" {
  bucket = aws_s3_bucket.dlq_archive.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# No part of this bucket is ever public. Archived transactions contain member
# IDs and basket contents.
resource "aws_s3_bucket_public_access_block" "dlq_archive" {
  bucket = aws_s3_bucket.dlq_archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 90-day retention: long enough to cover the firmware-upgrade cycle that a
# poison batch triggers and any follow-up audit, short enough that archived
# member data is not kept indefinitely.
resource "aws_s3_bucket_lifecycle_configuration" "dlq_archive" {
  bucket = aws_s3_bucket.dlq_archive.id

  # Versioning must settle before the lifecycle rules that reference
  # noncurrent versions are evaluated.
  depends_on = [aws_s3_bucket_versioning.dlq_archive]

  rule {
    id     = "expire-archived-messages"
    status = "Enabled"

    # Empty filter = apply to every object in the bucket. The provider requires
    # an explicit `filter` or `prefix` on each rule.
    filter {}

    expiration {
      days = 90
    }

    # Because versioning is Enabled above, `expiration` only writes a delete
    # marker — the object data itself would survive forever as a noncurrent
    # version and keep accruing storage charges. This rule is what actually
    # reclaims it, so the 90-day retention is real rather than nominal.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # A Path B archive upload interrupted mid-incident would otherwise leave
    # billable multipart fragments behind indefinitely.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
