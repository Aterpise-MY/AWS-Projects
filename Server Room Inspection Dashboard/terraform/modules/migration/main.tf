# ===========================================================================
# migration module — in-VPC schema-migration / query Lambda (Phase 1).
# ---------------------------------------------------------------------------
# Applies the version-controlled DDL to the private RDS instance and serves as
# a reusable migration + verification mechanism for later phases. Runs in the
# private-app subnets with the app SG (which already reaches the data SG:5432).
# Dedicated least-privilege role: VPC ENI mgmt + GetSecretValue on the db
# secret + KMS Decrypt only.
# ===========================================================================

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-migration-lambda"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = { Name = "${var.name_prefix}-migration-lambda" }
}

# ENI create/delete/describe for VPC-attached Lambda + basic logging.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "inline" {
  statement {
    sid       = "ReadDbSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }
  statement {
    sid       = "DecryptSecret"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "inline" {
  name   = "${var.name_prefix}-migration-lambda-inline"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.inline.json
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.name_prefix}-migration"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
}

resource "aws_lambda_function" "this" {
  function_name = "${var.name_prefix}-migration"
  description   = "Applies SRID schema DDL to RDS and runs verification queries."
  role          = aws_iam_role.this.arn
  runtime       = "python3.12"
  handler       = "handler.handler"
  architectures = ["x86_64"]
  timeout       = 120
  memory_size   = 256

  filename         = var.package_path
  source_code_hash = filebase64sha256(var.package_path)

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = var.security_group_ids
  }

  environment {
    variables = {
      DB_SECRET_ARN = var.db_secret_arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.vpc_access,
    aws_iam_role_policy.inline,
    aws_cloudwatch_log_group.this,
  ]

  tags = { Name = "${var.name_prefix}-migration" }
}
