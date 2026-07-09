###############################################################################
# INPUT VARIABLES
###############################################################################

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Base name used in resource names. Kept short (some SSM names are length-limited)."
  type        = string
  default     = "ssm-patching"
}

variable "environment" {
  description = "Deployment environment (prod, staging, dev). Also applied as a default tag."
  type        = string
  default     = "prod"
}

variable "application" {
  description = "Application tag applied to every demo EC2 instance."
  type        = string
  default     = "revenue-cycle-platform"
}

###############################################################################
# NETWORKING (self-contained minimal VPC)
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the project VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet that hosts the demo instances."
  type        = string
  default     = "10.20.1.0/24"
}

###############################################################################
# DEMO EC2 TARGETS
###############################################################################

variable "instance_count" {
  description = <<-EOT
    TOTAL number of demo EC2 instances to launch. Instances are distributed
    round-robin across the patch groups defined in `patch_groups` (sorted by
    map key). The default of 2 produces exactly one Amazon Linux 2023 target
    (prod-al2023) and one Ubuntu 22.04 target (prod-ubuntu). Set to 4 for two
    of each, etc.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.instance_count >= 1
    error_message = "instance_count must be at least 1."
  }
}

variable "patch_groups" {
  description = <<-EOT
    Definition of each patch group / OS family. The map key is a short label;
    `patch_group` is the value written to the reserved `Patch Group` instance
    tag and MUST match the maintenance-window target filter exactly. `os_family`
    selects which AMI SSM public parameter is used for the instance.
  EOT
  type = map(object({
    patch_group   = string
    os_family     = string # "amazon-linux-2023" or "ubuntu-22.04"
    instance_type = string
  }))
  default = {
    al2023 = {
      patch_group   = "prod-al2023"
      os_family     = "amazon-linux-2023"
      instance_type = "t3.micro"
    }
    ubuntu = {
      patch_group   = "prod-ubuntu"
      os_family     = "ubuntu-22.04"
      instance_type = "t3.micro"
    }
  }

  validation {
    condition = alltrue([
      for g in values(var.patch_groups) :
      contains(["amazon-linux-2023", "ubuntu-22.04"], g.os_family)
    ])
    error_message = "Each patch_groups entry os_family must be 'amazon-linux-2023' or 'ubuntu-22.04'."
  }
}

###############################################################################
# PATCH BASELINE TUNING
###############################################################################

variable "approve_after_days" {
  description = "Auto-approval delay (days) for patches matching an approval rule. Aligns with the Critical-CVE <= 7d VM-SLA."
  type        = number
  default     = 7
}

###############################################################################
# MAINTENANCE WINDOWS
###############################################################################

variable "al2023_schedule" {
  description = "6-field cron for the Amazon Linux 2023 maintenance window (UTC). Staggered ahead of Ubuntu."
  type        = string
  default     = "cron(0 2 ? * SUN *)"
}

variable "ubuntu_schedule" {
  description = "6-field cron for the Ubuntu maintenance window (UTC). One hour after the AL2023 window."
  type        = string
  default     = "cron(0 3 ? * SUN *)"
}

variable "window_duration_hours" {
  description = "Maintenance window duration in hours."
  type        = number
  default     = 2
}

variable "window_cutoff_hours" {
  description = <<-EOT
    Hours before the window end when SSM stops STARTING new tasks. The AWS API
    accepts whole hours only, so the requested 30-minute cutoff is expressed as
    the minimum representable value of 1 hour.
  EOT
  type    = number
  default = 1
}

variable "max_concurrency" {
  description = "Max % (or count) of targets patched simultaneously by the Run Command task."
  type        = string
  default     = "25%"
}

variable "max_errors" {
  description = "Max number (or %) of errors tolerated before the task stops."
  type        = string
  default     = "2"
}

###############################################################################
# ALERTING
###############################################################################

variable "alert_email" {
  description = "Optional email subscribed to the patch-alerts SNS topic. Leave empty to create the topic with no subscription. The subscriber must confirm via email."
  type        = string
  default     = ""
}
