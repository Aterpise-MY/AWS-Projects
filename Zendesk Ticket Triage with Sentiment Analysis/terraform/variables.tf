variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "zendesk-triage"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging, or prod."
  }
}

variable "lambda_memory_mb" {
  description = "Memory allocated to the Lambda function in MB"
  type        = number
  default     = 256

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 10240
    error_message = "lambda_memory_mb must be between 128 and 10240."
  }
}

variable "lambda_timeout_seconds" {
  description = "Maximum execution time for the Lambda function in seconds"
  type        = number
  default     = 15

  validation {
    condition     = var.lambda_timeout_seconds >= 1 && var.lambda_timeout_seconds <= 900
    error_message = "lambda_timeout_seconds must be between 1 and 900."
  }
}

variable "comprehend_language_code" {
  description = "Language code passed to AWS Comprehend DetectSentiment"
  type        = string
  default     = "en"

  validation {
    condition     = contains(["en", "es", "fr", "de", "it", "pt", "ar", "hi", "ja", "ko", "zh", "zh-TW"], var.comprehend_language_code)
    error_message = "comprehend_language_code must be a language supported by Comprehend DetectSentiment."
  }
}

variable "negative_confidence_threshold" {
  description = "Minimum NEGATIVE confidence (0-1) that escalates a ticket to priority=urgent"
  type        = number
  default     = 0.80

  validation {
    condition     = var.negative_confidence_threshold > 0 && var.negative_confidence_threshold <= 1
    error_message = "negative_confidence_threshold must be between 0 and 1."
  }
}

variable "positive_confidence_threshold" {
  description = "Minimum POSITIVE confidence (0-1) that tags a ticket positive_sentiment"
  type        = number
  default     = 0.80

  validation {
    condition     = var.positive_confidence_threshold > 0 && var.positive_confidence_threshold <= 1
    error_message = "positive_confidence_threshold must be between 0 and 1."
  }
}

variable "zendesk_subdomain" {
  description = "Zendesk subdomain (the part before .zendesk.com) used to build the Tickets API base URL"
  type        = string
  default     = "your-subdomain"
}

variable "zendesk_escalation_group_id" {
  description = "Zendesk group_id that urgent negative tickets are assigned to (0 leaves group unchanged)"
  type        = number
  default     = 0
}

variable "alert_email" {
  description = "Email address subscribed to the SNS negative-sentiment alert topic (empty creates no subscription)"
  type        = string
  default     = ""
}

variable "cloudwatch_retention_days" {
  description = "Retention period for the Lambda and API Gateway CloudWatch log groups"
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.cloudwatch_retention_days)
    error_message = "cloudwatch_retention_days must be a valid CloudWatch retention value."
  }
}

variable "alarm_lambda_error_threshold" {
  description = "Number of Lambda errors in one evaluation period before the alarm triggers"
  type        = number
  default     = 5
}

variable "alarm_api_5xx_threshold" {
  description = "Number of API Gateway 5XX errors in one evaluation period before the alarm triggers"
  type        = number
  default     = 5
}

variable "alarm_api_4xx_threshold" {
  description = "Number of API Gateway 4XX errors in one evaluation period before the alarm triggers — high 4XX may indicate failed HMAC verification"
  type        = number
  default     = 25
}
