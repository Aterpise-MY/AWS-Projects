variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module (for example ticketing-dev). Also the Secrets Manager path prefix."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC the database security group is created in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs forming the DB subnet group. At least two, in different availability zones, even for a Single-AZ instance."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "RDS requires a DB subnet group spanning at least two availability zones."
  }
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach MySQL on 3306. Source-security-group references only; no CIDR ingress is created."
  type        = list(string)
}

variable "instance_class" {
  description = "RDS instance class. Graviton (t4g) to match the rest of the platform."
  type        = string
  default     = "db.t4g.micro"
}

variable "engine_version" {
  description = "MySQL engine version. A major.minor value lets RDS select the current patch release."
  type        = string
  default     = "8.0"
}

variable "parameter_group_family" {
  description = "RDS parameter group family. Must match the major.minor of engine_version."
  type        = string
  default     = "mysql8.0"
}

variable "allocated_storage" {
  description = "Allocated storage in GiB for the gp3 data volume."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Upper bound in GiB for RDS storage autoscaling. Set equal to allocated_storage to disable autoscaling."
  type        = number
  default     = 50
}

variable "db_name" {
  description = "Name of the initial MySQL schema created on the instance."
  type        = string
  default     = "ticketing"
}

variable "username" {
  description = "Master username for the instance. RDS reserves 'admin' and 'root', hence the project-specific value."
  type        = string
  default     = "ticketing_admin"
}

variable "max_connections" {
  description = "Optional override for the MySQL max_connections parameter. Leave null to keep the engine default formula."
  type        = string
  default     = null
}

variable "backup_retention_period" {
  description = "Number of days of automated backups retained. Must be at least 1 for point-in-time recovery to exist at all."
  type        = number
  default     = 1
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window in days. 0 deletes the secret immediately on destroy, which is required for repeatable teardown of a dev environment."
  type        = number
  default     = 0
}

variable "tags" {
  description = "Base tags inherited from the root module. The module merges Component = data on top of these."
  type        = map(string)
  default     = {}
}
