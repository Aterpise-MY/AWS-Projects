variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project, used for resource naming"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "service_name" {
  description = "Name of the App Runner service"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.service_name))
    error_message = "Service name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.ecr_repository_name))
    error_message = "ECR repository name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "image_tag" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}

variable "image_tag_mutability" {
  description = "Whether image tags are mutable (MUTABLE or IMMUTABLE)"
  type        = string
  default     = "MUTABLE"
  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "Image tag mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "enable_image_scanning" {
  description = "Enable ECR image scanning on push"
  type        = bool
  default     = true
}

variable "container_port" {
  description = "Port exposed by the container"
  type        = number
  default     = 8080
  validation {
    condition     = var.container_port > 0 && var.container_port < 65536
    error_message = "Container port must be between 1 and 65535."
  }
}

variable "cpu" {
  description = "CPU configuration (256, 512, 1024, 2048, 4096)"
  type        = string
  default     = "256"
  validation {
    condition     = contains(["256", "512", "1024", "2048", "4096"], var.cpu)
    error_message = "CPU must be 256, 512, 1024, 2048, or 4096."
  }
}

variable "memory" {
  description = "Memory configuration (512, 1024, 2048, 3072, 4096)"
  type        = string
  default     = "512"
  validation {
    condition     = contains(["512", "1024", "2048", "3072", "4096"], var.memory)
    error_message = "Memory must be 512, 1024, 2048, 3072, or 4096."
  }
}

variable "min_instances" {
  description = "Minimum number of instances for auto scaling"
  type        = number
  default     = 1
  validation {
    condition     = var.min_instances > 0 && var.min_instances <= 25
    error_message = "Min instances must be between 1 and 25."
  }
}

variable "max_instances" {
  description = "Maximum number of instances for auto scaling"
  type        = number
  default     = 4
  validation {
    condition     = var.max_instances > 0 && var.max_instances <= 25
    error_message = "Max instances must be between 1 and 25."
  }
}

variable "max_concurrency" {
  description = "Maximum concurrent requests per instance"
  type        = number
  default     = 100
  validation {
    condition     = var.max_concurrency >= 1 && var.max_concurrency <= 200
    error_message = "Max concurrency must be between 1 and 200."
  }
}

variable "environment_variables" {
  description = "Environment variables for the container"
  type        = map(string)
  default     = {}
}

variable "environment_secrets" {
  description = "Environment secrets (ARN references) for the container"
  type        = map(string)
  default     = {}
}

variable "is_publicly_accessible" {
  description = "Whether the service is publicly accessible"
  type        = bool
  default     = true
}

variable "egress_type" {
  description = "Egress type (DEFAULT or VPC)"
  type        = string
  default     = "DEFAULT"
  validation {
    condition     = contains(["DEFAULT", "VPC"], var.egress_type)
    error_message = "Egress type must be DEFAULT or VPC."
  }
}

variable "vpc_connector_arn" {
  description = "ARN of VPC connector for VPC egress (required if egress_type is VPC)"
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "Log retention must be a valid CloudWatch retention value."
  }
}

variable "cpu_alarm_threshold" {
  description = "CPU utilization threshold (%) for CloudWatch alarm"
  type        = number
  default     = 80
  validation {
    condition     = var.cpu_alarm_threshold > 0 && var.cpu_alarm_threshold <= 100
    error_message = "CPU alarm threshold must be between 0 and 100."
  }
}

variable "memory_alarm_threshold" {
  description = "Memory utilization threshold (%) for CloudWatch alarm"
  type        = number
  default     = 80
  validation {
    condition     = var.memory_alarm_threshold > 0 && var.memory_alarm_threshold <= 100
    error_message = "Memory alarm threshold must be between 0 and 100."
  }
}
