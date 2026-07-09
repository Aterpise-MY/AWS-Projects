variable "name_prefix" {
  description = "Resource name prefix (e.g. mcf-srid-prod)."
  type        = string
}

variable "db_subnet_ids" {
  description = "Private-data subnet IDs (2 AZ) for the DB subnet group."
  type        = list(string)
}

variable "data_sg_id" {
  description = "Data-tier security group ID (already allows 5432 from app SG)."
  type        = string
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key ARN for storage + PI encryption."
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16.14"
}

variable "instance_class" {
  description = "RDS instance class (right-sized SMALL for a 2-room tool)."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial gp3 storage (GiB)."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Storage-autoscaling ceiling (GiB). 0 disables autoscaling."
  type        = number
  default     = 50
}

variable "db_name" {
  description = "Application database name."
  type        = string
  default     = "inspections"
}

variable "master_username" {
  description = "RDS master username (not the app role)."
  type        = string
  default     = "srid_admin"
}

variable "app_username" {
  description = "Least-privilege application login role name."
  type        = string
  default     = "srid_app"
}

variable "backup_retention_period" {
  description = "Automated backup retention (days)."
  type        = number
  default     = 7
}

variable "backup_window" {
  description = "Daily backup window (UTC). SGT 09:00-09:30 = 01:00-01:30 UTC."
  type        = string
  default     = "17:00-17:30"
}

variable "maintenance_window" {
  description = "Weekly maintenance window (UTC)."
  type        = string
  default     = "sun:18:00-sun:18:30"
}

variable "deletion_protection" {
  description = "Guard against accidental deletion. Disable before teardown."
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = "Enable Performance Insights (7-day free retention)."
  type        = bool
  default     = true
}
