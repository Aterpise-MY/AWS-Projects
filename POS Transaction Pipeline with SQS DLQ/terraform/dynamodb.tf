###############################################################################
# DynamoDB — idempotency table
#
# R4: after a redrive, a replayed transaction must not award points twice.
# Consumers do a conditional PutItem with
# `attribute_not_exists(transaction_id)` before doing any side-effecting work;
# a ConditionalCheckFailedException means "already processed, skip".
#
# The claim is released again (DeleteItem) when the side effect fails, so a
# retried message is not misread as a duplicate and silently dropped. That is
# why the execution role grants PutItem AND DeleteItem on this table.
#
# Idempotency is a PREREQUISITE for redrive, not an optional extra: SQS is
# at-least-once even without a redrive, and a redrive deliberately re-delivers
# messages that may have partially succeeded before failing.
###############################################################################

resource "aws_dynamodb_table" "processed_transactions" {
  name = "${var.name_prefix}-processed-transactions"

  # PAY_PER_REQUEST: the workload swings from ~6,000 tx/hour baseline to
  # ~25,000 tx/hour at Chinese New Year and 11.11 (§1). Provisioned capacity
  # would either throttle the peak or be wasted for the other 50 weeks.
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "transaction_id"

  attribute {
    name = "transaction_id"
    type = "S"
  }

  # 7-day TTL. Long enough to cover a realistic detect-fix-redrive cycle, short
  # enough that the table stays small and cheap. DynamoDB deletes expired items
  # within ~48 hours of `expires_at`, so treat 7 days as a floor, not an exact
  # eviction time.
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false # Lab only. Enable for production — see README security notes.
  }

  tags = {
    Name = "${var.name_prefix}-processed-transactions"
    Role = "idempotency"
  }
}
