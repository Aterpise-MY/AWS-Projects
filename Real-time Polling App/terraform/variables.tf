variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "realtime-polling"
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

variable "stage_name" {
  description = "WebSocket API stage name (becomes the URL path segment)"
  type        = string
  default     = "production"
}

variable "lambda_memory_mb" {
  description = "Memory allocated to each Lambda function in MB"
  type        = number
  default     = 256

  validation {
    condition     = var.lambda_memory_mb >= 128 && var.lambda_memory_mb <= 10240
    error_message = "lambda_memory_mb must be between 128 and 10240."
  }
}

variable "lambda_timeout_seconds" {
  description = "Maximum execution time for each Lambda function in seconds"
  type        = number
  default     = 10

  validation {
    condition     = var.lambda_timeout_seconds >= 1 && var.lambda_timeout_seconds <= 900
    error_message = "lambda_timeout_seconds must be between 1 and 900."
  }
}

variable "connection_ttl_seconds" {
  description = "Seconds before an idle WebSocket connection record auto-expires via DynamoDB TTL"
  type        = number
  default     = 7200 # 2 hours
}

variable "cloudwatch_retention_days" {
  description = "Retention period for all CloudWatch log groups"
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.cloudwatch_retention_days)
    error_message = "cloudwatch_retention_days must be a valid CloudWatch retention value."
  }
}

variable "alarm_lambda_error_threshold" {
  description = "Number of Lambda errors in one evaluation period before alarm triggers"
  type        = number
  default     = 5
}

variable "alarm_integration_error_threshold" {
  description = "Number of WebSocket integration errors in one evaluation period before alarm triggers"
  type        = number
  default     = 10
}
