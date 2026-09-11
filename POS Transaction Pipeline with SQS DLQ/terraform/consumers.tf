###############################################################################
# Consumer lanes
#
# Three calls of the same module, differing only in the four parameters that
# scenario §5 specifies. That is the point of the design: "queue + DLQ +
# redrive + alarms + consumer" is one reusable unit, and onboarding a fourth
# downstream service is a ~10-line module block, not a copy-paste of 15
# resources.
#
#   name       lambda_timeout  visibility_timeout  maxReceiveCount  retry window
#   ---------  --------------  ------------------  ---------------  ------------
#   loyalty          30 s            180 s (6x)            5           ~15 min
#   inventory        20 s            120 s (6x)            5           ~10 min
#   einvoice         60 s            360 s (6x)            8           ~48 min
#
# All three zip the SAME `lambda/` tree so each handler can `import common`;
# they differ only in which handler is the entrypoint.
###############################################################################

locals {
  # Shared across all three lanes.
  lambda_source_dir = "${path.root}/../lambda"

  # Convenience map used by outputs.tf to build per-service output maps and
  # ready-to-paste redrive commands without repeating the three module names.
  consumers = {
    loyalty   = module.loyalty
    inventory = module.inventory
    einvoice  = module.einvoice
  }
}

###############################################################################
# Loyalty — third-party loyalty platform API
#
# 30 s timeout: the loyalty platform is a slow external HTTP dependency.
# maxReceiveCount 5 is the AWS recommended minimum for Lambda consumers.
# The resulting ~15-minute retry window is deliberately SHORTER than the
# 40-minute outage in the Phase 4 drill — the drill is supposed to push
# messages into the DLQ so the redrive path gets exercised. The fix for a
# 40-minute outage is error classification and replay, not an ever-larger
# maxReceiveCount that would also burn 15 attempts on every poison message.
###############################################################################

module "loyalty" {
  source = "./modules/consumer_queue"

  name        = "loyalty"
  name_prefix = var.name_prefix

  sns_topic_arn        = aws_sns_topic.pos_transactions.arn
  sns_delivery_dlq_arn = aws_sqs_queue.sns_delivery_dlq.arn
  alarm_topic_arn      = aws_sns_topic.ops_alerts.arn

  lambda_timeout     = 30
  visibility_timeout = 180
  max_receive_count  = 5

  batch_size               = var.batch_size
  source_retention_seconds = var.source_retention_seconds
  dlq_retention_seconds    = var.dlq_retention_seconds
  log_retention_days       = var.log_retention_days

  dynamodb_table_name = aws_dynamodb_table.processed_transactions.name
  dynamodb_table_arn  = aws_dynamodb_table.processed_transactions.arn

  lambda_source_dir = local.lambda_source_dir
  lambda_handler    = "loyalty/handler.lambda_handler"

  # Phase 4 outage drill switch (§8).
  extra_environment = {
    LOYALTY_API_DOWN = tostring(var.loyalty_api_down)
  }
}

###############################################################################
# Inventory — internal stock deduction and replenishment
#
# Fastest of the three (internal service, 20 s timeout) and therefore the
# shortest retry window at ~10 minutes. Separate queue and DLQ mean a loyalty
# platform outage leaves stock deduction completely untouched — the blast-radius
# property asserted by TC-05.
###############################################################################

module "inventory" {
  source = "./modules/consumer_queue"

  name        = "inventory"
  name_prefix = var.name_prefix

  sns_topic_arn        = aws_sns_topic.pos_transactions.arn
  sns_delivery_dlq_arn = aws_sqs_queue.sns_delivery_dlq.arn
  alarm_topic_arn      = aws_sns_topic.ops_alerts.arn

  lambda_timeout     = 20
  visibility_timeout = 120
  max_receive_count  = 5

  batch_size               = var.batch_size
  source_retention_seconds = var.source_retention_seconds
  dlq_retention_seconds    = var.dlq_retention_seconds
  log_retention_days       = var.log_retention_days

  dynamodb_table_name = aws_dynamodb_table.processed_transactions.name
  dynamodb_table_arn  = aws_dynamodb_table.processed_transactions.arn

  lambda_source_dir = local.lambda_source_dir
  lambda_handler    = "inventory/handler.lambda_handler"
}

###############################################################################
# e-Invoice — tax authority submission API
#
# The only lane that deviates from maxReceiveCount 5, and the reason matters:
# the tax authority API is rate-limited and returns HTTP 429 frequently under
# load. A 429 is a purely transient failure that WILL succeed on retry once the
# token bucket refills, so spending extra receives on it is cheap and correct.
# 8 receives x 360 s visibility gives a ~48-minute retry window, enough to ride
# out a sustained throttling period without escalating to a human.
#
# Raising maxReceiveCount is only defensible here because the dominant failure
# mode is transient. Applying 8 to the loyalty lane would mean every poison
# message from firmware v2.3 wastes 8 invocations instead of 5 (§5 trade-off).
#
# Failure here is a COMPLIANCE risk, not just a customer-experience one, which
# is why the 60 s timeout is generous and the retry window is the longest.
###############################################################################

module "einvoice" {
  source = "./modules/consumer_queue"

  name        = "einvoice"
  name_prefix = var.name_prefix

  sns_topic_arn        = aws_sns_topic.pos_transactions.arn
  sns_delivery_dlq_arn = aws_sqs_queue.sns_delivery_dlq.arn
  alarm_topic_arn      = aws_sns_topic.ops_alerts.arn

  lambda_timeout     = 60
  visibility_timeout = 360
  max_receive_count  = 8

  batch_size               = var.batch_size
  source_retention_seconds = var.source_retention_seconds
  dlq_retention_seconds    = var.dlq_retention_seconds
  log_retention_days       = var.log_retention_days

  dynamodb_table_name = aws_dynamodb_table.processed_transactions.name
  dynamodb_table_arn  = aws_dynamodb_table.processed_transactions.arn

  lambda_source_dir = local.lambda_source_dir
  lambda_handler    = "einvoice/handler.lambda_handler"

  # Throttling drill switch: fraction of submissions that simulate an HTTP 429.
  extra_environment = {
    EINVOICE_THROTTLE_RATE = tostring(var.einvoice_throttle_rate)
  }
}
