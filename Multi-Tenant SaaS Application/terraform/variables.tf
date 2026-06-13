variable "region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "ID of the existing VPC in which to deploy RDS and Lambda"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for RDS subnet group and Lambda VPC config (minimum 2, in different AZs for Multi-AZ)"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets are required for Multi-AZ RDS."
  }
}

variable "db_password" {
  description = "Master password for the RDS PostgreSQL instance (also stored in Secrets Manager)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 8
    error_message = "db_password must be at least 8 characters."
  }
}

variable "common_tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default = {
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

variable "environment_name" {
  description = "Short environment label used in resource names and tags (dev/staging/prod)"
  type        = string
  default     = "prod"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment_name)
    error_message = "environment_name must be dev, staging, or prod."
  }
}

variable "db_instance_class" {
  description = "RDS instance class — use smaller sizes for dev/staging to reduce cost"
  type        = string
  default     = "db.t3.medium"
}

variable "multi_az" {
  description = "Enable RDS Multi-AZ standby — should be true for staging and prod"
  type        = bool
  default     = true
}
