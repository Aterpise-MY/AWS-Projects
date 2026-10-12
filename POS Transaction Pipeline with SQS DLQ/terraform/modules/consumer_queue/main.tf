###############################################################################
# module "consumer_queue"
#
# One reusable lane of the SNS fan-out pipeline:
#
#   pos-transactions (SNS)
#        |  raw message delivery, subscription DLQ -> pos-sns-delivery-dlq
#        v
#   <prefix>-<name>-queue  --(maxReceiveCount)-->  <prefix>-<name>-dlq
#        |                                              |
#        v                                              v
#   <prefix>-<name>-fn (Lambda)                   2 CloudWatch alarms
#        |
#        v
#   pos-processed-transactions (DynamoDB idempotency)
#
# Scenario reference: Enterprise_DLQ_Scenario_POS_EN.md §4 and §5.
###############################################################################

locals {
  base_name     = "${var.name_prefix}-${var.name}"
  queue_name    = "${local.base_name}-queue"
  dlq_name      = "${local.base_name}-dlq"
  function_name = "${local.base_name}-fn"

  # Approximate retry window before a message lands in the DLQ (scenario §5.3).
  # Surfaced in tags so an on-call engineer can read it off the console.
  retry_window_seconds = var.max_receive_count * var.visibility_timeout
}

###############################################################################
# 1. Dead-letter queue
#
# Retention is 14 days (the SQS maximum) and MUST exceed the source queue's
# 4-day retention. Trap: for *Standard* queues the expiry clock is the original
# enqueue timestamp on the source queue, and moving a message to a DLQ does NOT
# reset it. If both retentions were 4 days, a message that already sat 3 days in
# the source queue would survive only 1 more day in the DLQ. (FIFO queues do
# reset the timestamp; this pipeline deliberately uses Standard — see §4.)
###############################################################################

resource "aws_sqs_queue" "dlq" {
  name                      = local.dlq_name
  message_retention_seconds = var.dlq_retention_seconds

  # SSE-SQS (AWS-managed keys). Avoids the ~USD 1/month per-key cost of a
  # customer managed KMS key while still encrypting at rest (§11).
  sqs_managed_sse_enabled = true

  tags = {
    Name      = local.dlq_name
    Service   = var.name
    QueueRole = "dead-letter"
  }
}

###############################################################################
# 2. Source queue
#
# visibility_timeout_seconds is sized at >= 6x the Lambda timeout (§5.1). The
# precondition below fails the plan if that invariant is ever broken by a
# future parameter change.
###############################################################################

resource "aws_sqs_queue" "source" {
  name                       = local.queue_name
  visibility_timeout_seconds = var.visibility_timeout
  message_retention_seconds  = var.source_retention_seconds
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = {
    Name               = local.queue_name
    Service            = var.name
    QueueRole          = "source"
    RetryWindowSeconds = tostring(local.retry_window_seconds)
  }

  lifecycle {
    # 11. AWS recommends a visibility timeout of at least 6x the function
    # timeout for SQS event source mappings, so a throttled or retried
    # invocation still finishes before the message becomes visible again and
    # burns a receive. Lambda separately refuses to create the event source
    # mapping if function timeout > visibility timeout, so violating this is a
    # deploy-time failure, not a runtime surprise.
    precondition {
      condition     = var.visibility_timeout >= 6 * var.lambda_timeout
      error_message = "visibility_timeout (${var.visibility_timeout}s) must be >= 6 x lambda_timeout (${var.lambda_timeout}s = ${6 * var.lambda_timeout}s) for consumer '${var.name}'. AWS recommends visibility timeout >= 6x function timeout for SQS event source mappings (scenario §5.1)."
    }
  }
}

###############################################################################
# 3. Redrive ALLOW policy on the DLQ
#
# Declared as the standalone `aws_sqs_queue_redrive_allow_policy` resource
# rather than inline on `aws_sqs_queue.dlq`. This is deliberate: the source
# queue's redrive_policy references the DLQ ARN, and the allow policy
# references the source queue ARN. Inlining the allow policy in the DLQ
# resource would make the two aws_sqs_queue resources reference each other and
# Terraform would fail with a dependency cycle. Splitting the allow policy into
# its own resource breaks the cycle: dlq -> source -> allow_policy.
#
# `byQueue` narrows redrive permission to this lane's own source queue, so
# nobody can redrive loyalty DLQ messages into the inventory queue.
###############################################################################

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.source.arn]
  })
}

###############################################################################
# 4. Source queue policy — let SNS deliver, but only from our topic
#
# Without the aws:SourceArn condition any SNS topic in any account could push
# messages into this queue. This is the first thing to check when a publish
# succeeds but the queue stays empty (§8 Phase 1 hint).
###############################################################################

data "aws_iam_policy_document" "source_queue" {
  statement {
    sid    = "AllowSNSTopicToSendMessage"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.source.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.sns_topic_arn]
    }
  }
}

resource "aws_sqs_queue_policy" "source" {
  queue_url = aws_sqs_queue.source.id
  policy    = data.aws_iam_policy_document.source_queue.json
}

###############################################################################
# 5. SNS subscription
#
# raw_message_delivery = true so the Lambda receives the bare transaction JSON
# in `body` instead of an SNS envelope it would have to unwrap.
#
# redrive_policy here is the SUBSCRIPTION-level DLQ. An SQS redrive policy only
# catches *consumer* failures — messages that were successfully delivered to
# the queue and then failed processing. If SNS cannot hand the message to the
# queue at all (queue policy deleted, KMS key policy wrong, queue gone), the
# failure happens at the SNS layer and never touches the SQS DLQ. This is the
# safety net for TC-07.
###############################################################################

resource "aws_sns_topic_subscription" "this" {
  topic_arn            = var.sns_topic_arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.source.arn
  raw_message_delivery = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = var.sns_delivery_dlq_arn
  })

  # The queue policy must exist before SNS starts delivering, otherwise the
  # first messages bounce straight into the subscription DLQ.
  depends_on = [aws_sqs_queue_policy.source]
}

###############################################################################
# 6. Lambda deployment package
#
# The whole `lambda/` tree is zipped (not just `lambda/<name>/`) so handlers can
# `import common`. Tests and bytecode caches are excluded to keep the package
# deterministic — a stray __pycache__ would change source_code_hash on every
# machine and cause spurious redeploys.
###############################################################################

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = var.lambda_source_dir
  output_path = "${path.root}/.build/${local.function_name}.zip"

  excludes = [
    "test_handlers.py",
    "**/__pycache__/**",
    "__pycache__",
  ]
}

###############################################################################
# 7. Log group
#
# Created explicitly (rather than letting Lambda auto-create it on first
# invocation) so retention is managed and so the IAM policy can be scoped to
# this exact log group ARN instead of `*`.
###############################################################################

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name    = "/aws/lambda/${local.function_name}"
    Service = var.name
  }
}

###############################################################################
# 8. Execution role — least privilege
#
# Deliberately NOT using AWSLambdaBasicExecutionRole or
# AWSLambdaSQSQueueExecutionRole: both grant `Resource: "*"`. Every grant below
# is pinned to a single ARN. The only wildcard is the `:*` log-stream suffix on
# the log group ARN, which CloudWatch Logs requires because stream names are
# generated per execution environment.
###############################################################################

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = {
    Name    = "${local.function_name}-role"
    Service = var.name
  }
}

data "aws_iam_policy_document" "lambda" {
  # The event source mapping polls on the function's behalf using these
  # permissions. ChangeMessageVisibility is what lets the Lambda service back
  # off in-flight messages when the function is throttled.
  statement {
    sid    = "ConsumeSourceQueue"
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]

    resources = [aws_sqs_queue.source.arn]
  }

  # Idempotency (R4) — the consumer uses a claim/release pair, so BOTH actions
  # are load-bearing:
  #
  #   PutItem    conditional write with attribute_not_exists(transaction_id)
  #              takes the claim before the side effect runs.
  #   DeleteItem releases the claim when the side effect then fails.
  #
  # DeleteItem is not an optimisation. Without it `common.idempotency.release()`
  # fails silently, the claim outlives the failed attempt, and the SQS
  # redelivery sees an existing claim, classifies the message as a duplicate and
  # drops it. The transaction is never processed and never reaches a DLQ — the
  # exact silent-loss mode R4 exists to prevent.
  #
  # GetItem is deliberately NOT granted: the conditional PutItem is itself the
  # read-and-test, so the consumer never issues a bare read. No UpdateItem
  # either — claims are created and deleted, never mutated, and stale ones are
  # reaped by the 7-day TTL.
  statement {
    sid    = "IdempotencyClaimAndRelease"
    effect = "Allow"

    actions = [
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]

    resources = [var.dynamodb_table_arn]
  }

  # logs:CreateLogGroup is intentionally omitted — the group is created by
  # Terraform above, so the function never needs permission to create one.
  statement {
    sid    = "WriteOwnLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${local.function_name}-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

###############################################################################
# 9. Consumer function
###############################################################################

resource "aws_lambda_function" "this" {
  function_name = local.function_name
  role          = aws_iam_role.lambda.arn
  runtime       = "python3.12"
  handler       = var.lambda_handler
  timeout       = var.lambda_timeout
  memory_size   = 256

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = merge(
      {
        SERVICE           = var.name
        IDEMPOTENCY_TABLE = var.dynamodb_table_name
        LOG_LEVEL         = "INFO"
      },
      var.extra_environment,
    )
  }

  # Depend on the log group so Lambda never races ahead and auto-creates an
  # unmanaged, never-expiring log group on first invocation.
  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy.lambda,
  ]

  tags = {
    Name    = local.function_name
    Service = var.name
  }
}

###############################################################################
# 10. Event source mapping
#
# function_response_types = ["ReportBatchItemFailures"] is what satisfies R2.
# Without it, one poison message in a batch of 10 makes the whole batch
# reappear on the queue, so the 9 good transactions are reprocessed on every
# retry — inflating receive counts and, absent idempotency, awarding points
# multiple times.
###############################################################################

resource "aws_lambda_event_source_mapping" "this" {
  event_source_arn = aws_sqs_queue.source.arn
  function_name    = aws_lambda_function.this.arn
  batch_size       = var.batch_size
  enabled          = true

  function_response_types = ["ReportBatchItemFailures"]
}

###############################################################################
# 11. DLQ alarms
#
# treat_missing_data = "notBreaching": SQS only emits queue metrics while a
# queue is active. An idle, empty DLQ publishes nothing, and the default
# "missing" treatment would leave the alarm stuck in INSUFFICIENT_DATA rather
# than a clean OK.
###############################################################################

# R3 — alert within 5 minutes of the FIRST message reaching the DLQ.
# 1 datapoint over a 60-second period, so worst case is ~60s of metric
# aggregation plus SQS's ~1-minute publish interval: comfortably inside 5 min.
#
# Alarming on ApproximateNumberOfMessagesVisible (a gauge) rather than
# NumberOfMessagesSent (a count) means the alarm stays in ALARM for as long as
# the DLQ is non-empty, and only returns to OK once the backlog is actually
# drained or redriven. A count-based alarm would self-clear after one period
# while the messages were still sitting there.
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${local.base_name}-dlq-not-empty"
  alarm_description   = "R3: ${local.dlq_name} contains at least one message. Triage per docs/runbook-dlq.md — identify the failure class, then redrive (transient) or archive and delete (poison)."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.alarm_topic_arn]
  ok_actions    = [var.alarm_topic_arn]

  tags = {
    Name    = "${local.base_name}-dlq-not-empty"
    Service = var.name
  }
}

# Second-chance alarm: a message older than 7 days is halfway through the
# 14-day DLQ retention. Past that point the clock to permanent loss is short,
# and for a Standard queue the age shown is measured from the ORIGINAL enqueue
# on the source queue, so the real remaining headroom is smaller than it looks.
resource "aws_cloudwatch_metric_alarm" "dlq_message_aging" {
  alarm_name          = "${local.base_name}-dlq-message-aging"
  alarm_description   = "Oldest message in ${local.dlq_name} is older than 7 days and is approaching the 14-day retention limit. Handle it now or it will be silently deleted — the exact failure mode this project exists to prevent."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 604800 # 7 days in seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.alarm_topic_arn]
  ok_actions    = [var.alarm_topic_arn]

  tags = {
    Name    = "${local.base_name}-dlq-message-aging"
    Service = var.name
  }
}
