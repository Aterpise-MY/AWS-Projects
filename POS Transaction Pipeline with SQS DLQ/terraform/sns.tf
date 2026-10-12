###############################################################################
# SNS — transaction fan-out, ops alerting, and the SNS-layer delivery DLQ
#
# Scenario reference: Enterprise_DLQ_Scenario_POS_EN.md §4.
###############################################################################

###############################################################################
# pos-transactions — the fan-out topic
#
# 180 stores publish every completed sale here; the topic fans it out to the
# three consumer lanes. Standard (not FIFO) on purpose: AWS documents that
# attaching a DLQ to a FIFO queue breaks exact ordering, because once a message
# is moved out of the group the following messages continue. POS transactions
# have no ordering dependency, so Standard queues plus DynamoDB idempotency is
# the better trade (§4).
###############################################################################

resource "aws_sns_topic" "pos_transactions" {
  name         = "${var.name_prefix}-transactions"
  display_name = "MekarMart POS transactions"

  tags = {
    Name = "${var.name_prefix}-transactions"
    Role = "transaction-fanout"
  }
}

###############################################################################
# pos-ops-alerts — destination for every CloudWatch DLQ alarm action (R3)
###############################################################################

resource "aws_sns_topic" "ops_alerts" {
  name         = "${var.name_prefix}-ops-alerts"
  display_name = "POS pipeline ops alerts"

  tags = {
    Name = "${var.name_prefix}-ops-alerts"
    Role = "ops-alerting"
  }
}

# Optional email subscription. AWS sends a confirmation email that must be
# clicked before any alarm is delivered; until then the subscription shows as
# `PendingConfirmation` and Terraform will keep it in state that way.
resource "aws_sns_topic_subscription" "ops_alerts_email" {
  count = var.ops_alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = var.ops_alert_email
}

###############################################################################
# pos-sns-delivery-dlq — subscription-level DLQ
#
# Shared by all three SNS -> SQS subscriptions. This catches a failure class
# the per-consumer SQS DLQs structurally cannot see: SNS being unable to
# deliver to the queue in the first place (queue policy removed, KMS key policy
# wrong, queue deleted). Those messages never reach a source queue, so they
# never accumulate a receive count and never trigger an SQS redrive policy.
# This is the safety net exercised by TC-07.
#
# 14-day retention matches the consumer DLQs — an undelivered transaction is no
# less valuable than a failed one.
###############################################################################

resource "aws_sqs_queue" "sns_delivery_dlq" {
  name                      = "${var.name_prefix}-sns-delivery-dlq"
  message_retention_seconds = var.dlq_retention_seconds
  sqs_managed_sse_enabled   = true

  tags = {
    Name      = "${var.name_prefix}-sns-delivery-dlq"
    QueueRole = "sns-delivery-dead-letter"
  }
}

# SNS writes to this queue on behalf of the `pos-transactions` topic, so the
# policy is scoped with the same aws:SourceArn condition used on the consumer
# queues. Without this policy a delivery failure would itself fail to be
# recorded, which is the worst possible outcome for a safety net.
data "aws_iam_policy_document" "sns_delivery_dlq" {
  statement {
    sid    = "AllowSNSTopicToSendMessage"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.sns_delivery_dlq.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.pos_transactions.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "sns_delivery_dlq" {
  queue_url = aws_sqs_queue.sns_delivery_dlq.id
  policy    = data.aws_iam_policy_document.sns_delivery_dlq.json
}

###############################################################################
# Alarm on the SNS delivery DLQ (R1 / TC-07)
#
# Declared here rather than in module "consumer_queue" because this queue sits
# outside the per-lane modules: it is shared by all three subscriptions and has
# no source queue, no Lambda and no redrive path of its own.
#
# Thresholds deliberately mirror the module's `<lane>-dlq-not-empty` alarm so
# the on-call sees identical behaviour whichever DLQ fires.
#
# This is arguably the highest-severity alarm in the stack. A consumer DLQ
# means one message failed processing; this queue filling up means SNS could
# not hand messages to a subscribed queue AT ALL — a deleted queue policy or a
# broken KMS key policy — so an entire fan-out leg may be dropping 100% of its
# traffic while the consumer lane looks perfectly healthy (its queue is simply
# empty, and an empty queue raises no alarm). Runbook Path C.
###############################################################################

resource "aws_cloudwatch_metric_alarm" "sns_delivery_dlq_not_empty" {
  alarm_name          = "${var.name_prefix}-sns-delivery-dlq-not-empty"
  alarm_description   = "R1/TC-07: SNS could not deliver to a subscribed queue and the message landed in ${aws_sqs_queue.sns_delivery_dlq.name}. This is an SNS-layer delivery failure, NOT a consumer failure - the message never reached a source queue. Check queue policies and KMS key policies. Runbook: docs/runbook-dlq.md Path C. Note that StartMessageMoveTask does NOT work on this queue; recovery is a manual re-publish."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.sns_delivery_dlq.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.ops_alerts.arn]
  ok_actions    = [aws_sns_topic.ops_alerts.arn]

  tags = {
    Name      = "${var.name_prefix}-sns-delivery-dlq-not-empty"
    QueueRole = "sns-delivery-dead-letter"
  }
}
