# Retry model for hourly runs
# ---------------------------
# Lambda timeout 600 s, visibility timeout 900 s (= timeout + 300), maxReceiveCount 2:
# attempt 1 at HH:00, one automatic retry ~HH:15, then the sync DLQ at ~HH:30. The next
# scheduled run is at most an hour away, so more retries would only overlap it.
#
# This deliberately departs from AWS's "visibility timeout >= 6x function timeout" advice.
# That advice guards against throttled batches on busy queues being redelivered while the
# poller is still retrying the invoke. This queue carries <= 17 messages a day with
# batch_size 1 and maximum_concurrency 2, so throttling is not a realistic failure mode.
# The variable validation still enforces visibility >= timeout.

resource "aws_sqs_queue" "sync_dlq" {
  name                      = "${local.name}-sync-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "trigger" {
  name                       = "${local.name}-trigger"
  visibility_timeout_seconds = local.visibility_timeout
  message_retention_seconds  = 86400 # a sync message older than a day is useless
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.sync_dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "sync_dlq" {
  queue_url = aws_sqs_queue.sync_dlq.id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.trigger.arn]
  })
}

# Scheduler could not deliver (IAM drift, queue/Lambda deleted). Shared by sync and report schedules.
resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${local.name}-scheduler-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

# Reporter async invocation failed after 2 Lambda retries (on_failure destination).
resource "aws_sqs_queue" "report_dlq" {
  name                      = "${local.name}-report-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}
