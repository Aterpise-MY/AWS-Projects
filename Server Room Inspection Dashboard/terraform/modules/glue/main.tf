# ===========================================================================
# glue module — synthetic backfill (Phase 1).
# ---------------------------------------------------------------------------
# * Dedicated backfill S3 bucket (encrypted, versioned, public-access-blocked)
#   holding the Glue script + synthetic legacy CSV. Distinct from the future
#   Phase 2 AppFlow raw-landing bucket.
# * A Glue NETWORK connection places the Python-shell job in a private-app
#   subnet with a Glue SG allowed to reach the data SG on 5432, so the job can
#   connect to the private, non-public RDS.
# * Least-privilege Glue role: read the backfill bucket, read the db secret,
#   decrypt with the CMK, plus AWS-managed Glue service perms (ENI mgmt).
# ===========================================================================

locals {
  bucket_name = "${var.name_prefix}-backfill-${var.account_id}-${var.region_short}"
}

# ------------------------------ Backfill bucket ----------------------------
resource "aws_s3_bucket" "backfill" {
  bucket        = local.bucket_name
  force_destroy = true
  tags          = { Name = local.bucket_name }
}

resource "aws_s3_bucket_ownership_controls" "backfill" {
  bucket = aws_s3_bucket.backfill.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "backfill" {
  bucket                  = aws_s3_bucket.backfill.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "backfill" {
  bucket = aws_s3_bucket.backfill.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backfill" {
  bucket = aws_s3_bucket.backfill.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

# ------------------------- Objects: script + CSV ---------------------------
resource "aws_s3_object" "job_script" {
  bucket      = aws_s3_bucket.backfill.id
  key         = "scripts/backfill_job.py"
  source      = var.script_local_path
  source_hash = filemd5(var.script_local_path)
}

resource "aws_s3_object" "backfill_csv" {
  bucket      = aws_s3_bucket.backfill.id
  key         = var.backfill_key
  source      = var.csv_local_path
  source_hash = filemd5(var.csv_local_path)
}

# ------------------------------- Glue SG -----------------------------------
# Glue requires a self-referencing all-TCP rule on the SG used by a connection.
resource "aws_security_group" "glue" {
  name        = "${var.name_prefix}-glue-sg"
  description = "Glue connection ENIs: self-ref (Glue requirement) + egress to RDS/NAT"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-glue-sg"
    Tier = "private-app"
  }
}

resource "aws_vpc_security_group_ingress_rule" "glue_self" {
  security_group_id            = aws_security_group.glue.id
  description                  = "Self-referencing all-TCP (Glue connection requirement)"
  ip_protocol                  = "tcp"
  from_port                    = 0
  to_port                      = 65535
  referenced_security_group_id = aws_security_group.glue.id
}

resource "aws_vpc_security_group_egress_rule" "glue_all" {
  security_group_id = aws_security_group.glue.id
  description       = "All outbound (RDS 5432 + NAT to S3/Secrets/PyPI)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Allow the Glue SG to reach the private RDS on 5432 (added to the data SG).
resource "aws_vpc_security_group_ingress_rule" "data_from_glue" {
  security_group_id            = var.data_sg_id
  description                  = "PostgreSQL from Glue SG (backfill)"
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  referenced_security_group_id = aws_security_group.glue.id
}

# ---------------------------- Glue connection ------------------------------
# NETWORK type: provides VPC placement (subnet + SG) with NO stored credentials
# — the job authenticates to RDS with the Secrets Manager creds via psycopg2.
resource "aws_glue_connection" "rds" {
  name            = "${var.name_prefix}-rds-network"
  connection_type = "NETWORK"

  physical_connection_requirements {
    availability_zone      = var.availability_zone
    subnet_id              = var.glue_subnet_id
    security_group_id_list = [aws_security_group.glue.id]
  }
}

# ------------------------------- Glue IAM ----------------------------------
data "aws_iam_policy_document" "glue_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "glue" {
  name               = "${var.name_prefix}-glue-backfill"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
  tags               = { Name = "${var.name_prefix}-glue-backfill" }
}

# AWS-managed Glue service role (ENI mgmt for VPC connections, Glue APIs, logs).
resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "glue_inline" {
  statement {
    sid       = "ReadBackfillBucket"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.backfill.arn, "${aws_s3_bucket.backfill.arn}/*"]
  }
  statement {
    sid       = "ReadDbSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }
  statement {
    sid       = "UseCmk"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "glue_inline" {
  name   = "${var.name_prefix}-glue-backfill-inline"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_inline.json
}

# -------------------------------- Glue job ---------------------------------
resource "aws_glue_job" "backfill" {
  name         = "${var.name_prefix}-backfill"
  description  = "One-off synthetic legacy-CSV backfill into RDS inspection_log."
  role_arn     = aws_iam_role.glue.arn
  glue_version = "1.0"
  max_capacity = 1.0
  connections  = [aws_glue_connection.rds.name]

  command {
    name            = "pythonshell"
    python_version  = "3.9"
    script_location = "s3://${aws_s3_bucket.backfill.id}/${aws_s3_object.job_script.key}"
  }

  default_arguments = {
    "--job-language"              = "python"
    "--additional-python-modules" = "psycopg2-binary==2.9.9"
    "--backfill_bucket"           = aws_s3_bucket.backfill.id
    "--backfill_key"              = var.backfill_key
    "--db_secret_arn"             = var.db_secret_arn
    "--region"                    = var.region
    "--TempDir"                   = "s3://${aws_s3_bucket.backfill.id}/tmp/"
  }

  max_retries = 0
  execution_property {
    max_concurrent_runs = 1
  }

  tags = { Name = "${var.name_prefix}-backfill" }
}
