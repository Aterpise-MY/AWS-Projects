# ---------------------------------------------------------------------------
# compute module inputs — Phase 3 dashboard serving layer.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Resource name prefix (e.g. mcf-srid-prod)."
  type        = string
}

variable "region" {
  description = "AWS region (for awslogs driver + ECR URLs)."
  type        = string
}

variable "account_id" {
  description = "AWS account ID."
  type        = string
}

variable "vpc_id" {
  description = "VPC the ALB target group binds to."
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the internet-facing ALB."
  type        = list(string)
}

variable "app_subnet_ids" {
  description = "Private-app subnet IDs the Fargate tasks run in."
  type        = list(string)
}

variable "app_sg_id" {
  description = "App/Fargate security group ID (ingress from ALB on app_port)."
  type        = string
}

variable "alb_sg_id" {
  description = "ALB security group ID."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK ARN encrypting the ECR repo and CloudWatch log group."
  type        = string
}

variable "db_secret_arn" {
  description = "DB credentials secret ARN the app reads at startup (task role)."
  type        = string
}

variable "ecs_task_execution_role_arn" {
  description = "ECS task execution role ARN (image pull / log write)."
  type        = string
}

variable "ecs_task_execution_role_name" {
  description = "ECS task execution role name (for the inline policy add)."
  type        = string
}

variable "ecs_task_role_arn" {
  description = "ECS task (runtime) role ARN — the app's identity."
  type        = string
}

variable "ecs_task_role_name" {
  description = "ECS task role name (for the inline policy add)."
  type        = string
}

variable "app_port" {
  description = "Container/host port the dashboard listens on."
  type        = number
  default     = 8080
}

variable "container_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)."
  type        = number
  default     = 256
}

variable "container_memory" {
  description = "Fargate task memory in MiB (512 = 0.5 GB)."
  type        = number
  default     = 512
}

variable "desired_count" {
  description = "Desired number of running tasks."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the dashboard log group."
  type        = number
  default     = 30
}

variable "image_tag" {
  description = "Container image tag the task definition references."
  type        = string
  default     = "latest"
}

variable "alb_listener_port" {
  description = "ALB listener port (80 for the HTTP demo; 443 for HTTPS)."
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "Target group health-check path."
  type        = string
  default     = "/healthz"
}

variable "health_check_matcher" {
  description = "Target group health-check success matcher."
  type        = string
  default     = "200"
}

variable "health_check_interval" {
  description = "Seconds between target group health checks."
  type        = number
  default     = 30
}

variable "healthy_threshold" {
  description = "Consecutive successes before a target is healthy."
  type        = number
  default     = 2
}

variable "unhealthy_threshold" {
  description = "Consecutive failures before a target is unhealthy."
  type        = number
  default     = 3
}
