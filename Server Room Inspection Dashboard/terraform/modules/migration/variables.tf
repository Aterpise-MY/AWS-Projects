variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
}

variable "subnet_ids" {
  description = "Private-app subnet IDs the Lambda runs in (reach RDS on 5432)."
  type        = list(string)
}

variable "security_group_ids" {
  description = "SG IDs for the Lambda ENIs (app SG — already allowed to RDS)."
  type        = list(string)
}

variable "db_secret_arn" {
  description = "ARN of the db credentials secret the Lambda reads."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK ARN used to decrypt the db secret."
  type        = string
}

variable "package_path" {
  description = "Path to the pre-built Lambda deployment zip."
  type        = string
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the Lambda."
  type        = number
  default     = 30
}
