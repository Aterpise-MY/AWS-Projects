variable "project_name" {
  description = "Base name used in all resource names and tags."
  type        = string
  default     = "scalable-webapp"
}

variable "environment" {
  description = "Deployment environment (e.g. prod, staging, dev)."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.3.0/24", "10.0.4.0/24"]
}

variable "instance_type" {
  description = "EC2 instance type for the Auto Scaling Group."
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "AMI ID for the launch template (Amazon Linux 2023 or Ubuntu for your region). Must be supplied by the user."
  type        = string
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair to assign to instances (used for emergency SSH access)."
  type        = string
}

variable "asg_min_size" {
  description = "Minimum number of instances in the Auto Scaling Group."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  description = "Maximum number of instances in the Auto Scaling Group."
  type        = number
  default     = 6
}

variable "asg_desired_capacity" {
  description = "Desired number of instances in the Auto Scaling Group at launch."
  type        = number
  default     = 2
}

variable "cpu_scale_out_threshold" {
  description = "CPU utilization percentage that triggers a scale-out event (add 1 instance)."
  type        = number
  default     = 70
}

variable "cpu_scale_in_threshold" {
  description = "CPU utilization percentage that triggers a scale-in event (remove 1 instance)."
  type        = number
  default     = 30
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN for the HTTPS listener. Leave empty to skip HTTPS."
  type        = string
  default     = ""
}

variable "alarm_email" {
  description = "Email address that receives CloudWatch alarm notifications. Must confirm the SNS subscription via email."
  type        = string
}

variable "web_server" {
  description = "Web server to install on instances. Accepted values: 'nginx' or 'apache'."
  type        = string
  default     = "nginx"

  validation {
    condition     = contains(["nginx", "apache"], var.web_server)
    error_message = "web_server must be either 'nginx' or 'apache'."
  }
}
