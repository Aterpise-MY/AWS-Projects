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

variable "database_subnet_cidrs" {
  description = "List of CIDR blocks for the database subnets (one per AZ). These subnets get their own route tables with no NAT gateway route and no internet gateway route."
  type        = list(string)
  default     = ["10.0.5.0/24", "10.0.6.0/24"]

  validation {
    condition     = length(var.database_subnet_cidrs) >= 2
    error_message = "database_subnet_cidrs needs at least two CIDR blocks: an RDS DB subnet group must span two Availability Zones."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the Auto Scaling Group."
  type        = string
  default     = "t3.medium"
}

variable "ami_id" {
  description = "Optional AMI ID override for the launch template. Leave empty (the default) to resolve the latest Amazon Linux 2023 x86_64 AMI automatically. An override must be Amazon Linux 2023-compatible (x86_64): the user data uses dnf and Amazon Linux 2023 package names."
  type        = string
  default     = ""

  validation {
    condition     = var.ami_id == "" || can(regex("^ami-[0-9a-f]{8,17}$", var.ami_id))
    error_message = "ami_id must be empty or a valid AMI ID such as ami-0123456789abcdef0, with no surrounding whitespace."
  }
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

variable "domain_name" {
  description = "Fully qualified hostname served over HTTPS (for example webapp-nlb.example.com). An ACM certificate is issued for it and a Cloudflare CNAME points it at the NLB. Required."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    error_message = "domain_name must be a lowercase fully qualified hostname with no scheme, no wildcard and no trailing dot, for example webapp-nlb.example.com."
  }
}

variable "cloudflare_zone_id" {
  description = "ID of the Cloudflare zone that holds domain_name. The ACM validation CNAME and the hostname CNAME are created in this zone. Required. The Cloudflare API token is not a variable: export it as CLOUDFLARE_API_TOKEN."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be the 32-character hexadecimal zone ID shown on the zone's Overview page in the Cloudflare dashboard."
  }
}

variable "ssl_policy" {
  description = "ELB security policy for the NLB TLS:443 listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
}

variable "db_instance_class" {
  description = "RDS instance class for the PostgreSQL Multi-AZ DB instance."
  type        = string
  default     = "db.t3.micro"
}

variable "db_master_username" {
  description = "Master user name for the RDS instance. Must not be a PostgreSQL reserved word. There is no password variable: RDS generates the master password and keeps it in Secrets Manager."
  type        = string
  default     = "dbadmin"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,62}$", var.db_master_username))
    error_message = "db_master_username must start with a letter and contain 1 to 63 letters, digits or underscores."
  }
}

variable "db_backup_retention_period" {
  description = "Number of days RDS keeps automated backups (enables point-in-time recovery). 0 turns automated backups off."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_period >= 0 && var.db_backup_retention_period <= 35
    error_message = "db_backup_retention_period must be between 0 and 35 days."
  }
}

variable "db_deletion_protection" {
  description = "Turn on RDS deletion protection. Defaults to false because this stack is routinely destroyed; a production stack would set it to true."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final DB snapshot on destroy. Defaults to true because this stack holds no real data; a production stack would set it to false, which keeps a snapshot named <project_name>-<environment>-db-final."
  type        = bool
  default     = true
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
