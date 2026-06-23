variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "graphql-appsync-todo"
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

variable "log_level" {
  description = "AppSync field-level logging verbosity (NONE | ERROR | ALL)"
  type        = string
  default     = "ERROR"

  validation {
    condition     = contains(["NONE", "ERROR", "ALL"], var.log_level)
    error_message = "log_level must be NONE, ERROR, or ALL."
  }
}

variable "api_key_expires" {
  description = "Expiry timestamp for the AppSync API key (RFC 3339). Max 365 days from creation."
  type        = string
  default     = "2027-01-01T00:00:00Z"
}

variable "cloudwatch_retention_days" {
  description = "Retention period for AppSync CloudWatch log group"
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.cloudwatch_retention_days)
    error_message = "cloudwatch_retention_days must be a valid CloudWatch retention value."
  }
}

variable "alarm_5xx_threshold" {
  description = "Number of 5XX errors in one minute before alarm triggers"
  type        = number
  default     = 10
}

variable "alarm_4xx_threshold" {
  description = "Number of 4XX errors in one minute before alarm triggers"
  type        = number
  default     = 50
}

variable "alarm_latency_p99_ms" {
  description = "p99 latency threshold in milliseconds before alarm triggers"
  type        = number
  default     = 1000
}
