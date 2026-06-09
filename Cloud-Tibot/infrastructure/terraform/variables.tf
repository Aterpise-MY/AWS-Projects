/**
 * Project CORTEX - Variable Definitions
 * 
 * Defines input variables for infrastructure configuration,
 * including region, project settings, and sensitive credentials.
 */

variable "aws_region" {
  description = "AWS region for resource deployment"
  type        = string
  default     = "us-east-1"
}

variable "amplify_region" {
  description = "AWS region where Amplify app is deployed (for EventBridge cross-region)"
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Project name for resource naming and tagging"
  type        = string
  default     = "cortex"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "telegram_token" {
  description = "Telegram Bot API token for notifications"
  type        = string
  sensitive   = true
}

variable "telegram_chat_id" {
  description = "Telegram chat ID for sending messages"
  type        = string
  sensitive   = true
}

# Telegram Topic (Forum Thread) IDs for per-module message routing
variable "telegram_topic_auto_remediator" {
  description = "Telegram message_thread_id for Auto-Remediator topic (Module 1)"
  type        = string
  default     = ""
}

variable "telegram_topic_git_radar" {
  description = "Telegram message_thread_id for Git Radar topic (Module 2)"
  type        = string
  default     = ""
}

variable "telegram_topic_finops_sentinel" {
  description = "Telegram message_thread_id for FinOps Sentinel topic (Module 3)"
  type        = string
  default     = ""
}

variable "telegram_topic_guardian_alert" {
  description = "Telegram message_thread_id for CORTEX Guardian Alert topic (Module 4 results)"
  type        = string
  default     = ""
}

variable "telegram_topic_cortex_infra" {
  description = "Telegram message_thread_id for Cortex Infra Pipeline topic (topic 236) — plan approvals and deploy results"
  type        = string
  default     = ""
}

# GitHub App Authentication Variables (replaces github_pat)
variable "github_app_id" {
  description = "GitHub App ID for JWT authentication"
  type        = string
}

variable "github_app_installation_id" {
  description = "GitHub App Installation ID for generating access tokens"
  type        = string
}

variable "github_app_private_key" {
  description = "GitHub App Private Key (PEM format) for JWT signing"
  type        = string
  sensitive   = true
}

variable "github_repo_owner" {
  description = "GitHub repository owner (org or user) for Copilot agent operations"
  type        = string
}

variable "github_repo_name" {
  description = "GitHub repository name for Copilot agent operations"
  type        = string
}

variable "lambda_runtime" {
  description = "Lambda function runtime version"
  type        = string
  default     = "python3.11"
}

variable "lambda_timeout" {
  description = "Lambda function timeout in seconds (increased for AI agent loops)"
  type        = number
  default     = 300
}

variable "lambda_memory_size" {
  description = "Lambda function memory allocation in MB (increased for AI agent)"
  type        = number
  default     = 1024
}
