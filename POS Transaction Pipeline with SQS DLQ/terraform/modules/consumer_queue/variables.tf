###############################################################################
# module "consumer_queue" — input variables
#
# One call of this module produces a complete, isolated downstream lane:
#   SNS subscription -> source SQS queue -> Lambda consumer -> DLQ + alarms
#
# Scenario reference: Enterprise_DLQ_Scenario_POS_EN.md §4 (architecture)
# and §5 (DLQ design parameters).
###############################################################################

variable "name" {
  description = "Short service name for this consumer lane, e.g. `loyalty`, `inventory`, `einvoice`. Used as the middle segment of every resource name and as the SERVICE environment variable."
  type        = string
}

variable "name_prefix" {
  description = "Global resource name prefix, e.g. `pos`. Combined as `<name_prefix>-<name>-<resource>` to produce names such as `pos-loyalty-queue`."
  type        = string
}

variable "sns_topic_arn" {
  description = "ARN of the `pos-transactions` SNS topic that fans transactions out to this lane. Also used as the `aws:SourceArn` condition value in the source queue policy."
  type        = string
}

variable "sns_delivery_dlq_arn" {
  description = "ARN of the shared `pos-sns-delivery-dlq` SQS queue used as the subscription-level DLQ. Catches SNS-layer delivery failures (bad queue policy, bad KMS key policy) that an SQS redrive policy cannot see."
  type        = string
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds. Must be <= the queue visibility timeout or Lambda refuses to create the event source mapping."
  type        = number
}

variable "visibility_timeout" {
  description = "SQS visibility timeout in seconds. Must be at least 6x `lambda_timeout` per the AWS recommendation for Lambda consumers; enforced by a lifecycle precondition in main.tf."
  type        = number
}

variable "max_receive_count" {
  description = "Number of receives after which SQS moves a message to the DLQ. AWS recommends >= 5 for Lambda consumers. Approximate retry window = max_receive_count x visibility_timeout."
  type        = number

  validation {
    condition     = var.max_receive_count >= 5 && var.max_receive_count <= 1000
    error_message = "max_receive_count must be >= 5 (AWS recommended minimum for Lambda consumers, scenario §5.2) and <= 1000 (SQS hard limit)."
  }
}

variable "batch_size" {
  description = "Maximum number of SQS records delivered to the Lambda function per invocation."
  type        = number
  default     = 10
}

variable "source_retention_seconds" {
  description = "Message retention on the source queue. Default 345600 s = 4 days, per scenario §5."
  type        = number
  default     = 345600
}

variable "dlq_retention_seconds" {
  description = "Message retention on the DLQ. Default 1209600 s = 14 days (the SQS maximum). Must exceed `source_retention_seconds` — see the comment in main.tf on Standard-queue enqueue timestamps."
  type        = number
  default     = 1209600
}

variable "alarm_topic_arn" {
  description = "ARN of the `pos-ops-alerts` SNS topic that receives CloudWatch alarm actions for this lane's DLQ."
  type        = string
}

variable "dynamodb_table_name" {
  description = "Name of the `pos-processed-transactions` idempotency table, passed to the function as IDEMPOTENCY_TABLE."
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN of the idempotency table. Scopes the function's `dynamodb:PutItem` / `dynamodb:DeleteItem` grant to that single table — PutItem takes the idempotency claim with a conditional write, DeleteItem releases it when the side effect fails so the retry is not mistaken for a duplicate and dropped."
  type        = string
}

variable "lambda_source_dir" {
  description = "Directory zipped into the deployment package. All three lanes zip the whole `lambda/` tree so handlers can `import common`."
  type        = string
}

variable "lambda_handler" {
  description = "Lambda handler path relative to the package root, e.g. `loyalty/handler.lambda_handler`."
  type        = string
}

variable "extra_environment" {
  description = "Additional environment variables merged over the module's baseline set (SERVICE, IDEMPOTENCY_TABLE, LOG_LEVEL). Used for drill switches such as LOYALTY_API_DOWN."
  type        = map(string)
  default     = {}
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days for this lane's Lambda log group."
  type        = number
  default     = 14
}
