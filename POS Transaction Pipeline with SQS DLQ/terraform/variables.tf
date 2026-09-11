###############################################################################
# Root module input variables
###############################################################################

variable "aws_region" {
  description = "AWS region for every resource in this stack. SQS requires a DLQ to live in the same account and region as its source queue, so this is a single-region stack by design."
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. `pos` produces `pos-transactions`, `pos-loyalty-queue`, `pos-loyalty-dlq`, `pos-loyalty-fn`."
  type        = string
  default     = "pos"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,16}$", var.name_prefix))
    error_message = "name_prefix must be 2-17 lowercase alphanumeric or hyphen characters starting with a letter, so derived SQS queue and Lambda function names stay within AWS length limits."
  }
}

variable "ops_alert_email" {
  description = "Email address subscribed to the `pos-ops-alerts` SNS topic for DLQ alarms (R3). Leave empty to skip the subscription. AWS sends a confirmation email that must be clicked before alarms are delivered."
  type        = string
  default     = ""

  validation {
    condition     = var.ops_alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.ops_alert_email))
    error_message = "ops_alert_email must be empty or a valid email address."
  }
}

variable "loyalty_api_down" {
  description = "Phase 4 outage drill switch. When true the loyalty consumer simulates an HTTP 503 from the third-party loyalty platform, so transactions exhaust their retry window and land in `pos-loyalty-dlq`. Passed to the function as LOYALTY_API_DOWN."
  type        = bool
  default     = false
}

variable "einvoice_throttle_rate" {
  description = "Fraction of e-invoice submissions (0.0-1.0) that simulate an HTTP 429 from the rate-limited tax authority API. Passed to the function as EINVOICE_THROTTLE_RATE."
  type        = number
  default     = 0

  validation {
    condition     = var.einvoice_throttle_rate >= 0 && var.einvoice_throttle_rate <= 1
    error_message = "einvoice_throttle_rate must be between 0.0 and 1.0 inclusive."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention in days for all three consumer log groups. Must be a value CloudWatch accepts."
  type        = number
  default     = 14

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days
    )
    error_message = "log_retention_days must be one of the retention values CloudWatch Logs accepts (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653)."
  }
}

variable "source_retention_seconds" {
  description = "Message retention on all three source queues. 345600 s = 4 days per scenario §5. Must stay below `dlq_retention_seconds`."
  type        = number
  default     = 345600

  validation {
    condition     = var.source_retention_seconds >= 60 && var.source_retention_seconds <= 1209600
    error_message = "source_retention_seconds must be between 60 and 1209600 (SQS limits)."
  }
}

variable "dlq_retention_seconds" {
  description = "Message retention on all three DLQs and on `pos-sns-delivery-dlq`. 1209600 s = 14 days, the SQS maximum. Standard queues do not reset the enqueue timestamp when a message moves to a DLQ, so this must exceed the source retention or the DLQ window is silently shortened by the time already spent in the source queue."
  type        = number
  default     = 1209600

  validation {
    condition     = var.dlq_retention_seconds >= 60 && var.dlq_retention_seconds <= 1209600
    error_message = "dlq_retention_seconds must be between 60 and 1209600 (SQS limits)."
  }
}

variable "batch_size" {
  description = "SQS records delivered per Lambda invocation for all three consumers. Kept at 10 so the Phase 3 partial-batch-failure test (9 good + 1 poison) fits in a single batch."
  type        = number
  default     = 10

  validation {
    condition     = var.batch_size >= 1 && var.batch_size <= 10000
    error_message = "batch_size must be between 1 and 10000."
  }
}

variable "idempotency_ttl_days" {
  description = "Documented TTL horizon, in days, that consumers should write into the `expires_at` attribute of `pos-processed-transactions`. 7 days comfortably exceeds the 14-day DLQ retention risk window for same-day redrives while keeping the table small. Exposed as an output for the application code to read."
  type        = number
  default     = 7
}

variable "additional_tags" {
  description = "Extra tags merged into the provider `default_tags` set for every resource. Use for cost-allocation or change-ticket tags without editing providers.tf."
  type        = map(string)
  default     = {}
}
