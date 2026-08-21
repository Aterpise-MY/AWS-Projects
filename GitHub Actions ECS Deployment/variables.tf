###############################################################################
# INPUT VARIABLES
###############################################################################

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Base name used in resource names (kept short and DNS-safe)."
  type        = string
  default     = "gha-ecs"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric/hyphen, start with a letter, max 31 chars."
  }
}

variable "environment" {
  description = "Deployment environment (prod, staging, dev). Also applied as a default tag."
  type        = string
  default     = "prod"
}

###############################################################################
# NETWORKING
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the project VPC."
  type        = string
  default     = "10.30.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread the ALB and ECS tasks across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3 (ALB requires at least two AZs)."
  }
}

###############################################################################
# CONTAINER / TASK
###############################################################################

variable "ecr_repository_name" {
  description = "Name of the ECR repository the CI/CD pipeline pushes images to."
  type        = string
  default     = "northwind-storefront"
}

variable "container_name" {
  description = "Container name inside the task definition. MUST match `container-name` in the GitHub Actions workflow."
  type        = string
  default     = "my-container"
}

variable "container_image" {
  description = <<-EOT
    Image used for the FIRST `terraform apply` only. The ECR repo is empty on
    day one, so we bootstrap with a public placeholder. The GitHub Actions
    pipeline then registers new task-definition revisions pointing at your ECR
    image, and Terraform ignores those changes (see lifecycle block).
  EOT
  type        = string
  default     = "public.ecr.aws/nginx/nginx:latest"
}

variable "container_port" {
  description = "Port the container listens on (also the ALB target port)."
  type        = number
  default     = 80
}

variable "task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)."
  type        = number
  default     = 256
}

variable "task_memory" {
  description = "Fargate task memory in MiB. Must be valid for the chosen task_cpu."
  type        = number
  default     = 512
}

###############################################################################
# SERVICE & SCALING
###############################################################################

variable "desired_count" {
  description = "Initial number of running tasks. After first apply, the pipeline / autoscaler owns this."
  type        = number
  default     = 2
}

variable "min_capacity" {
  description = "Minimum tasks the Application Auto Scaling target will hold."
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum tasks the Application Auto Scaling target will scale out to."
  type        = number
  default     = 6
}

variable "cpu_target_value" {
  description = "Target average CPU utilization (%) for the target-tracking scaling policy."
  type        = number
  default     = 50
}

variable "health_check_path" {
  description = "HTTP path the ALB target group uses for health checks."
  type        = string
  default     = "/"
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the container log group."
  type        = number
  default     = 14
}
