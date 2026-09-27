variable "aws_region" {
  description = "AWS region for every resource."
  type        = string
  default     = "ap-southeast-1"
}

variable "project_name" {
  description = "Name prefix. local.name (= metric dimension Service) is \"<project_name>-<environment>\"."
  type        = string
  default     = "ebteqdesk-business-sync"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,40}$", var.project_name))
    error_message = "project_name must be 3-40 chars of lowercase letters, digits and hyphens."
  }
}

variable "environment" {
  description = "Environment suffix, e.g. prod."
  type        = string
  default     = "prod"
}

variable "owner" {
  description = "Owner tag."
  type        = string
  default     = "brendon"
}

variable "extra_tags" {
  description = "Additional tags merged into provider default_tags."
  type        = map(string)
  default     = {}
}

variable "ebteqdesk_base_url" {
  description = "Ebteqdesk base URL, https only, no trailing path (e.g. https://desk.ebteq.com)."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+/?$", var.ebteqdesk_base_url))
    error_message = "ebteqdesk_base_url must be https://<host> with no path."
  }
}

variable "portals" {
  description = "Per-brand sync schedule. Keys are brand portals; all keys are allowed for manual runs, only enabled ones are scheduled."
  type = map(object({
    schedule_expression   = string
    enabled               = bool
    expected_runs_per_day = number
  }))
  default = {
    salonv3 = { schedule_expression = "cron(0 9-17 ? * MON-FRI *)", enabled = true, expected_runs_per_day = 9 }
    warni   = { schedule_expression = "cron(30 9-16 ? * MON-FRI *)", enabled = false, expected_runs_per_day = 8 }
  }

  validation {
    condition     = length(var.portals) > 0 && alltrue([for k in keys(var.portals) : contains(["salonv3", "warni"], k)])
    error_message = "portals keys must be a non-empty subset of [\"salonv3\", \"warni\"]."
  }

  validation {
    condition = alltrue([
      for p in values(var.portals) : startswith(p.schedule_expression, "cron(") || startswith(p.schedule_expression, "rate(")
    ])
    error_message = "Each portals[*].schedule_expression must start with \"cron(\" or \"rate(\"."
  }

  validation {
    condition     = alltrue([for p in values(var.portals) : p.expected_runs_per_day >= 1 && floor(p.expected_runs_per_day) == p.expected_runs_per_day])
    error_message = "Each portals[*].expected_runs_per_day must be a whole number >= 1."
  }
}

variable "schedule_timezone" {
  description = "IANA timezone for every schedule expression."
  type        = string
  default     = "Asia/Kuala_Lumpur"
}

variable "report_schedule_expression" {
  description = "Daily Business Sync report schedule (in schedule_timezone)."
  type        = string
  default     = "cron(0 18 ? * MON-FRI *)"

  validation {
    condition     = startswith(var.report_schedule_expression, "cron(") || startswith(var.report_schedule_expression, "rate(")
    error_message = "report_schedule_expression must start with \"cron(\" or \"rate(\"."
  }
}

variable "lambda_timeout_seconds" {
  description = "Runner Lambda timeout. The runner polls Ebteqdesk until the sweep finishes or ~45 s before this."
  type        = number
  default     = 600

  validation {
    condition     = var.lambda_timeout_seconds >= 60 && var.lambda_timeout_seconds <= 900
    error_message = "lambda_timeout_seconds must be between 60 and 900."
  }
}

variable "visibility_timeout_seconds" {
  description = "Trigger queue visibility timeout. null = lambda_timeout_seconds + 300 (900 s by default): the retry gap."
  type        = number
  default     = null
  nullable    = true

  validation {
    condition     = var.visibility_timeout_seconds == null || try(var.visibility_timeout_seconds >= var.lambda_timeout_seconds, false)
    error_message = "visibility_timeout_seconds must be >= lambda_timeout_seconds, or SQS redelivers while the first attempt is still running."
  }
}

variable "max_receive_count" {
  description = "SQS deliveries per message before the sync DLQ. 2 = one automatic retry."
  type        = number
  default     = 2

  validation {
    condition     = var.max_receive_count >= 1 && var.max_receive_count <= 5
    error_message = "max_receive_count must be between 1 and 5."
  }
}

variable "runner_max_concurrency" {
  description = "SQS event source maximum concurrency (min 2 per AWS). One sweep per brand at a time is enforced by Ebteqdesk."
  type        = number
  default     = 2

  validation {
    condition     = var.runner_max_concurrency >= 2 && var.runner_max_concurrency <= 10
    error_message = "runner_max_concurrency must be between 2 and 10."
  }
}

variable "alert_every_n_failures" {
  description = "Final-failure Telegram alert on the 1st consecutive failure, then every Nth."
  type        = number
  default     = 3

  validation {
    condition     = var.alert_every_n_failures >= 1
    error_message = "alert_every_n_failures must be >= 1."
  }
}

variable "telegram_notify_on_success" {
  description = "Send a Telegram message for every successful sync (noisy with hourly runs; for the first day only)."
  type        = bool
  default     = false
}

variable "poll_interval_seconds" {
  description = "Seconds between GET /runs/{id} polls."
  type        = number
  default     = 10
}

variable "report_retention_days" {
  description = "Days before S3 run reports, failure records and daily reports expire."
  type        = number
  default     = 180
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for all three Lambda functions."
  type        = number
  default     = 90
}

variable "report_alarm_hours" {
  description = "Hours without a ReportGenerated datapoint before the reporter alarm fires. 74 = Fri 18:00 -> Mon 18:00 + 2 h."
  type        = number
  default     = 74

  validation {
    # CloudWatch: period * evaluation_periods <= 7 days for periods >= 1 hour.
    condition     = var.report_alarm_hours >= 1 && var.report_alarm_hours <= 168
    error_message = "report_alarm_hours must be between 1 and 168 (CloudWatch 7-day evaluation limit)."
  }
}
