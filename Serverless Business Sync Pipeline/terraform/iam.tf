data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------- runner

resource "aws_iam_role" "runner" {
  name               = "${local.name}-runner"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "runner" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.runner.arn}:*"]
  }
  statement {
    sid       = "ConsumeTriggerQueue"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
    resources = [aws_sqs_queue.trigger.arn]
  }
  statement {
    sid       = "WriteReports"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports.arn}/business-sync/*"]
  }
  statement {
    # Previous streak (consecutive_failures, last_success_at) is read before latest.json is overwritten.
    # No s3:ListBucket, so a brand's first-ever read returns 403 instead of 404; handler.py treats both as "no streak yet".
    sid       = "ReadLatest"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.reports.arn}/business-sync/*/latest.json"]
  }
  statement {
    sid       = "ReadSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ebteqdesk.arn, aws_secretsmanager_secret.telegram.arn]
  }
}

resource "aws_iam_role_policy" "runner" {
  name   = "runner"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner.json
}

# ---------------------------------------------------------------- notifier

resource "aws_iam_role" "notifier" {
  name               = "${local.name}-notifier"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "notifier" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.notifier.arn}:*"]
  }
  statement {
    sid       = "ReadTelegramSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.telegram.arn]
  }
}

resource "aws_iam_role_policy" "notifier" {
  name   = "notifier"
  role   = aws_iam_role.notifier.id
  policy = data.aws_iam_policy_document.notifier.json
}

# ---------------------------------------------------------------- reporter

resource "aws_iam_role" "reporter" {
  name               = "${local.name}-reporter"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "reporter" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.reporter.arn}:*"]
  }
  statement {
    sid       = "ListRunReports"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.reports.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["business-sync/*"]
    }
  }
  statement {
    sid       = "ReadRunReports"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.reports.arn}/business-sync/*"]
  }
  statement {
    sid       = "WriteDailyReports"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports.arn}/business-sync/daily-reports/*"]
  }
  statement {
    sid       = "ReadDlqDepth"
    actions   = ["sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.sync_dlq.arn, aws_sqs_queue.scheduler_dlq.arn]
  }
  statement {
    # Required by the async on_failure destination.
    sid       = "SendToReportDlq"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.report_dlq.arn]
  }
  statement {
    sid       = "ReadTelegramSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.telegram.arn]
  }
}

resource "aws_iam_role_policy" "reporter" {
  name   = "reporter"
  role   = aws_iam_role.reporter.id
  policy = data.aws_iam_policy_document.reporter.json
}

# ---------------------------------------------------------------- EventBridge Scheduler

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${local.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    sid       = "SendSyncMessages"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.trigger.arn, aws_sqs_queue.scheduler_dlq.arn]
  }
  statement {
    sid       = "InvokeReporter"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.reporter.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "scheduler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}
