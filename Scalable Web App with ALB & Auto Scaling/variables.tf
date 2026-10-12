variable "region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Short application name used as a prefix for all resource names."
  type        = string
  default     = "WebApp"
}

variable "environment" {
  description = "Deployment environment (e.g. production, staging, dev)."
  type        = string
  default     = "production"
}

# -----------------------------------------------------------------------------
# Networking — values must refer to an existing VPC and subnets
# -----------------------------------------------------------------------------

variable "vpc_id" {
  description = "ID of the existing VPC where resources will be deployed."
  type        = string
}

variable "subnet_ids" {
  description = <<-EOT
    List of pre-existing subnet IDs (e.g. us-east-1a). The us-east-1b subnet is
    Terraform-managed (aws_subnet.web_1b) and appended automatically.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "At least one pre-existing subnet ID is required."
  }
}

variable "public_route_table_id" {
  description = "ID of the route table with a 0.0.0.0/0 → IGW route. Used to make the us-east-1b subnet public."
  type        = string
}

variable "database_subnets" {
  description = <<-EOT
    Database subnets to create in the existing VPC, as a map of Availability
    Zone name to CIDR block. The CIDR blocks must be unused ranges inside the
    VPC. The subnets get their own route table with the local route only, so
    they have no path to an internet gateway or a NAT gateway. A DB subnet
    group needs at least two Availability Zones.
  EOT
  type        = map(string)
  default = {
    "us-east-1a" = "10.0.0.64/28"
    "us-east-1b" = "10.0.0.80/28"
  }

  validation {
    condition     = length(var.database_subnets) >= 2
    error_message = "database_subnets must name at least two Availability Zones."
  }

  validation {
    condition     = alltrue([for cidr in values(var.database_subnets) : can(cidrhost(cidr, 0))])
    error_message = "Every value in database_subnets must be a valid IPv4 CIDR block, for example 10.0.0.64/28."
  }
}

# -----------------------------------------------------------------------------
# HTTPS — hostname, certificate and DNS
# -----------------------------------------------------------------------------

variable "domain_name" {
  description = <<-EOT
    Fully qualified hostname the application is served on, in lower case
    (for example app.example.com). The ACM certificate is issued for this name
    and a Cloudflare CNAME points it at the load balancer. The name must sit in
    the Cloudflare zone given by cloudflare_zone_id.
  EOT
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}$", var.domain_name))
    error_message = "domain_name must be a lower-case fully qualified hostname with no trailing dot and no wildcard, for example app.example.com."
  }
}

variable "cloudflare_zone_id" {
  description = <<-EOT
    ID of the Cloudflare zone that holds domain_name (the 32-character
    hexadecimal identifier, not the zone name). The Cloudflare API token is
    never a variable: the provider reads it from the CLOUDFLARE_API_TOKEN
    environment variable.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "cloudflare_zone_id must be the 32-character lower-case hexadecimal zone ID."
  }
}

variable "ssl_policy" {
  description = "Name of the Elastic Load Balancing security policy for the HTTPS:443 listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09"
}

# -----------------------------------------------------------------------------
# EC2 / Launch Template
# -----------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type for the web application servers."
  type        = string
  default     = "t3.medium"
}

variable "key_pair_name" {
  description = <<-EOT
    Name of an existing EC2 key pair to associate with the instances. Leave
    empty to skip key association. Port 22 is not open in the EC2 security
    group; shell access is through Systems Manager Session Manager.
  EOT
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Database — RDS for PostgreSQL, Multi-AZ DB instance deployment
# -----------------------------------------------------------------------------

variable "db_instance_class" {
  description = "RDS DB instance class. Must be orderable for PostgreSQL in a Multi-AZ deployment in the target region."
  type        = string
  default     = "db.t3.micro"
}

variable "db_master_username" {
  description = <<-EOT
    Master user name for the database. Must start with a letter, contain only
    letters, digits and underscores, and must not be a word the engine
    reserves (for example admin). There is no password variable: RDS generates
    the master password and keeps it in Secrets Manager.
  EOT
  type        = string
  default     = "dbadmin"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9_]{0,62}$", var.db_master_username))
    error_message = "db_master_username must be 1 to 63 characters, start with a letter, and contain only letters, digits and underscores."
  }

  validation {
    condition     = !contains(["admin", "rdsadmin"], lower(var.db_master_username))
    error_message = "db_master_username must not be a reserved word such as admin or rdsadmin."
  }
}

variable "db_backup_retention_period" {
  description = "Number of days to keep automated database backups (0 to 35). 0 turns automated backups off."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_period >= 0 && var.db_backup_retention_period <= 35
    error_message = "db_backup_retention_period must be between 0 and 35."
  }
}

variable "db_deletion_protection" {
  description = "Turn on RDS deletion protection. Off by default so the stack can be destroyed; a production stack would turn it on."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot when the database is destroyed. True by default; a production stack would set it to false and keep the snapshot."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Auto Scaling
# -----------------------------------------------------------------------------

variable "asg_desired" {
  description = "Desired number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 2

  validation {
    condition     = var.asg_desired >= var.asg_min && var.asg_desired <= var.asg_max
    error_message = "asg_desired must be between asg_min and asg_max (inclusive)."
  }
}

variable "asg_min" {
  description = "Minimum number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 1
}

variable "asg_max" {
  description = "Maximum number of EC2 instances in the Auto Scaling Group."
  type        = number
  default     = 4
}

variable "scale_out_cpu_threshold" {
  description = "Average CPU utilisation percentage above which the ASG will scale out."
  type        = number
  default     = 60

  validation {
    condition     = var.scale_out_cpu_threshold > 0 && var.scale_out_cpu_threshold <= 100
    error_message = "CPU threshold must be between 1 and 100."
  }
}

variable "scale_in_cpu_threshold" {
  description = "Average CPU utilisation percentage below which the ASG will scale in."
  type        = number
  default     = 40

  validation {
    condition     = var.scale_in_cpu_threshold > 0 && var.scale_in_cpu_threshold < var.scale_out_cpu_threshold
    error_message = "scale_in_cpu_threshold must be greater than 0 and less than scale_out_cpu_threshold."
  }
}
