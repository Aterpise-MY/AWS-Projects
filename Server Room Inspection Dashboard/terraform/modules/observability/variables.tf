# ---------------------------------------------------------------------------
# observability module inputs — Phase 6 CloudWatch + AD Connector.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Resource name prefix (e.g. mcf-srid-prod)."
  type        = string
}

variable "region" {
  description = "AWS region (dashboard widgets)."
  type        = string
}

variable "alb_arn_suffix" {
  description = "ALB ARN suffix (AWS/ApplicationELB dimension)."
  type        = string
}

variable "target_group_arn_suffix" {
  description = "Target group ARN suffix (UnHealthyHostCount dimension)."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster name (AWS/ECS ClusterName dimension)."
  type        = string
}

variable "ecs_service_name" {
  description = "ECS service name (AWS/ECS ServiceName dimension)."
  type        = string
}

variable "db_instance_id" {
  description = "RDS instance identifier (AWS/RDS DBInstanceIdentifier dimension)."
  type        = string
}

variable "alarm_email" {
  description = "Email subscribed to the alarms SNS topic. Empty = no subscription created."
  type        = string
  default     = ""
}

# --- AD Connector (deploy-ready, gated) ------------------------------------
variable "enable_ad_connector" {
  description = "Create the AD Connector. Requires on-prem connectivity (VPN) to the DCs and a populated bind-account secret; left OFF by default."
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

variable "ad_vpc_id" {
  description = "VPC the AD Connector ENIs live in."
  type        = string
  default     = ""
}

variable "ad_subnet_ids" {
  description = "Two subnets (distinct AZs) for the AD Connector ENIs."
  type        = list(string)
  default     = []
}

variable "ad_bind_secret_arn" {
  description = "Secret ARN holding the AD service-account bind creds ({username,password} JSON)."
  type        = string
  default     = ""
}
