variable "region" {
  description = "AWS region where resources will be deployed"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "multitier-webapp"
}

variable "environment" {
  description = "Environment name (e.g., production, staging, development)"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "key_pair_name" {
  description = "Name of the EC2 Key Pair for SSH access (required)"
  type        = string
  validation {
    condition     = length(var.key_pair_name) > 0
    error_message = "key_pair_name must not be empty."
  }
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed for SSH access to bastion (WARNING: 0.0.0.0/0 is insecure)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  description = "EC2 instance type for web/app servers"
  type        = string
  default     = "t3.medium"
}

variable "bastion_instance_type" {
  description = "EC2 instance type for bastion host"
  type        = string
  default     = "t3.micro"
}

variable "db_username" {
  description = "Master username for RDS MySQL instance"
  type        = string
  default     = "admin"
}

variable "db_password" {
  description = "Master password for RDS MySQL instance (sensitive)"
  type        = string
  sensitive   = true
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.medium"
}

variable "db_allocated_storage" {
  description = "Allocated storage for RDS (GB)"
  type        = number
  default     = 20
}

variable "asg_min" {
  description = "Minimum number of instances in Auto Scaling Group"
  type        = number
  default     = 1
}

variable "asg_max" {
  description = "Maximum number of instances in Auto Scaling Group"
  type        = number
  default     = 4
}

variable "asg_desired" {
  description = "Desired number of instances in Auto Scaling Group"
  type        = number
  default     = 2
}

variable "cpu_scale_out_threshold" {
  description = "CPU percentage threshold to scale out"
  type        = number
  default     = 60
}

variable "cpu_scale_in_threshold" {
  description = "CPU percentage threshold to scale in"
  type        = number
  default     = 40
}
