# ---------------------------------------------------------------------------
# notifications module inputs — Phase 5 breach alerting.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Resource name prefix (e.g. mcf-srid-prod)."
  type        = string
}

variable "region" {
  description = "AWS region (Lambda env + SES)."
  type        = string
}

variable "enable_notifications" {
  description = "Master switch. When false the whole module is inert (no SES identities, Lambda, schedule, or IAM) so plan/apply is clean without verified SES identities."
  type        = bool
  default     = false
}

variable "sender_email" {
  description = "Verified SES sender identity. Required (and must be verified) before enabling."
  type        = string
  default     = ""
}

variable "recipient_emails" {
  description = "Recipient email addresses. In the SES sandbox each must also be a verified identity."
  type        = list(string)
  default     = []
}

variable "subnet_ids" {
  description = "Private-app subnet IDs for the in-VPC notifier Lambda."
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security group IDs for the notifier Lambda ENIs (app SG reaches RDS)."
  type        = list(string)
}

variable "db_secret_arn" {
  description = "DB credentials secret ARN the notifier reads."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK ARN used to decrypt the DB secret."
  type        = string
}

variable "lambda_execution_role_arn" {
  description = "Lambda execution role ARN the notifier assumes."
  type        = string
}

variable "lambda_execution_role_name" {
  description = "Lambda execution role name (for the inline SES/Secrets/KMS policy)."
  type        = string
}

variable "schedule_expression" {
  description = "EventBridge schedule for the digest. Default fires 08:30 and 20:30 UTC (after the AM/PM shifts)."
  type        = string
  default     = "cron(30 8,20 * * ? *)"
}

variable "notifier_package_path" {
  description = "Optional pre-built Lambda zip. When empty, the module zips ./src/handler.py itself (no external artifact needed)."
  type        = string
  default     = ""
}
