# ---------------------------------------------------------------------------
# Root input variables — Phase 0 foundations.
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Project identifier / name prefix root."
  type        = string
  default     = "mcf-srid"
}

variable "environment" {
  description = "Deployment environment."
  type        = string
  default     = "prod"
}

variable "cost_center" {
  description = "Cost-center tag value for chargeback."
  type        = string
  default     = "MCF-IT-Ops"
}

variable "availability_zones" {
  description = "AZs to span (2 for Phase 0)."
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public tier CIDRs (ALB/NAT), one per AZ."
  type        = list(string)
  default     = ["10.20.0.0/24", "10.20.1.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.availability_zones)
    error_message = "public_subnet_cidrs must have exactly one entry per availability_zone."
  }
}

variable "app_subnet_cidrs" {
  description = "Private-app tier CIDRs (Fargate/Lambda), one per AZ."
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.11.0/24"]

  # Cross-variable check: one CIDR per AZ across all tiers (TF >= 1.9).
  validation {
    condition     = length(var.app_subnet_cidrs) == length(var.availability_zones)
    error_message = "app_subnet_cidrs must have exactly one entry per availability_zone."
  }
}

variable "data_subnet_cidrs" {
  description = "Private-data tier CIDRs (RDS), one per AZ."
  type        = list(string)
  default     = ["10.20.20.0/24", "10.20.21.0/24"]

  validation {
    condition     = length(var.data_subnet_cidrs) == length(var.availability_zones)
    error_message = "data_subnet_cidrs must have exactly one entry per availability_zone."
  }
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT Gateway (cost control) vs one per AZ."
  type        = bool
  default     = true
}

variable "app_port" {
  description = "Port the app/Fargate service will listen on (later phase)."
  type        = number
  default     = 8080
}

variable "db_port" {
  description = "Database port for the data-tier SG."
  type        = number
  default     = 5432
}

variable "kms_alias" {
  description = "Alias for the customer-managed KMS key."
  type        = string
  default     = "alias/mcf-srid"
}

# --------------------------- Phase 1: Database -----------------------------
variable "db_engine_version" {
  description = "PostgreSQL engine version for the RDS instance."
  type        = string
  default     = "16.14"
}

variable "db_instance_class" {
  description = "RDS instance class (right-sized SMALL)."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_name" {
  description = "Application database name."
  type        = string
  default     = "inspections"
}

# --------------------------- Phase 3: Dashboard compute --------------------
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
  description = "Desired number of running dashboard tasks."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the dashboard container."
  type        = number
  default     = 30
}

variable "image_tag" {
  description = "Dashboard container image tag the task definition references."
  type        = string
  default     = "latest"
}

variable "alb_listener_port" {
  description = "ALB listener port. 80 for the HTTP demo; set to 443 (with an ACM cert) for HTTPS."
  type        = number
  default     = 80
}

variable "enable_http_ingress" {
  description = "Add the plain-HTTP ingress rule to the ALB SG for the Phase 3 demo. The existing 443 rule is always kept."
  type        = bool
  default     = true
}

variable "office_cidr" {
  description = "CIDR allowed to reach the ALB over HTTP. Defaults to 0.0.0.0/0 for the demo; NARROW to the MCF office egress CIDR because Phase 3 ships unauthenticated."
  type        = string
  default     = "0.0.0.0/0"
}

# --------------------------- Phase 4: Authentication (Cognito) -------------
variable "cognito_domain_prefix" {
  description = "Cognito hosted-UI domain prefix (globally unique across AWS). Empty = use the name prefix."
  type        = string
  default     = ""
}

variable "cognito_callback_urls" {
  description = "OAuth callback URLs for the Cognito app client. Populate with the ALB HTTPS URL before enabling ALB auth."
  type        = list(string)
  default     = []
}

variable "alb_https_enabled" {
  description = "Whether the ALB has an HTTPS listener. Prerequisite for ALB Cognito auth."
  type        = bool
  default     = false
}

variable "enable_cognito_alb_auth" {
  description = "Create the ALB authenticate-cognito listener rule. Only takes effect with alb_https_enabled."
  type        = bool
  default     = false
}

# --------------------------- Phase 5: Notifications ------------------------
variable "enable_notifications" {
  description = "Enable the SES/EventBridge breach-notifier stack. OFF by default (needs verified SES identities)."
  type        = bool
  default     = false
}

variable "ses_sender_email" {
  description = "Verified SES sender identity for breach digests."
  type        = string
  default     = ""
}

variable "ses_recipient_emails" {
  description = "Breach-digest recipients (verified identities in the SES sandbox)."
  type        = list(string)
  default     = []
}

variable "notification_schedule" {
  description = "EventBridge schedule for the digest. Default fires 08:30 and 20:30 UTC (after the AM/PM shifts)."
  type        = string
  default     = "cron(30 8,20 * * ? *)"
}

# --------------------------- Phase 6: Observability -----------------------
variable "alarm_email" {
  description = "Email subscribed to the CloudWatch alarms SNS topic. Empty = no subscription."
  type        = string
  default     = ""
}

variable "enable_ad_connector" {
  description = "Create the AD Connector. Needs on-prem VPN connectivity + a populated bind secret; OFF by default."
  type        = bool
  default     = false
}

variable "ad_directory_name" {
  description = "On-prem Active Directory domain name."
  type        = string
  default     = "corp.mcf.local"
}

variable "ad_dns_ips" {
  description = "On-prem AD DNS server IPs the connector forwards to."
  type        = list(string)
  default     = ["10.247.0.10", "10.247.0.11"]
}

variable "ad_subnet_ids" {
  description = "Subnets for the AD Connector ENIs. Empty = reuse the private-app subnets."
  type        = list(string)
  default     = []
}
