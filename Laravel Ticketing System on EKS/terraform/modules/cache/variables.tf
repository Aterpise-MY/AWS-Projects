variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module (for example ticketing-dev). Also the Secrets Manager path prefix."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC the cache security group is created in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs forming the ElastiCache subnet group."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 1
    error_message = "At least one private subnet is required for the ElastiCache subnet group."
  }
}

variable "allowed_security_group_ids" {
  description = "Security group IDs allowed to reach Redis on 6379. Source-security-group references only; no CIDR ingress is created."
  type        = list(string)
}

variable "node_type" {
  description = "ElastiCache node type. Graviton (t4g) to match the rest of the platform."
  type        = string
  default     = "cache.t4g.micro"
}

variable "engine_version" {
  description = "Redis OSS engine version."
  type        = string
  default     = "7.1"
}

variable "parameter_group_name" {
  description = "ElastiCache parameter group. Must match the engine major version of engine_version."
  type        = string
  default     = "default.redis7"
}

variable "port" {
  description = "TCP port the Redis primary listens on."
  type        = number
  default     = 6379
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
