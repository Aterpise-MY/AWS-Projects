variable "name_prefix" {
  description = "Prefix applied to the Name tag of every network resource, e.g. `ticketing-dev`."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be a /16 so the /19 pod subnets carved out of it fit."
  type        = string
  default     = "10.42.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 16
    error_message = "vpc_cidr must be a valid CIDR block of /16 or larger (prefix length <= 16)."
  }
}

variable "azs" {
  description = "Exactly two availability zone names to spread the public and private subnets across, e.g. [\"ap-southeast-1a\", \"ap-southeast-1b\"]."
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]

  validation {
    condition     = length(var.azs) == 2
    error_message = "azs must contain exactly two availability zones; the CIDR plan and subnet tagging assume two."
  }
}

variable "cluster_name" {
  description = "EKS cluster name used to build the `kubernetes.io/cluster/<name>` subnet discovery tags."
  type        = string
}

variable "enable_interface_endpoints" {
  description = "Create the four interface VPC endpoints (ECR API/DKR, STS, CloudWatch Logs). Default true for the production-shaped posture; set false in dev to save ~$76/month and route that egress through the single NAT Gateway (~$1/month of data processing at dev traffic). The free S3 gateway endpoint is always created regardless."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Create VPC Flow Logs to CloudWatch Logs. Off by default in dev because flow log ingestion is charged per GB."
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "CloudWatch Logs retention, in days, for the VPC flow log group. Ignored when enable_flow_logs is false."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Base tags merged into every resource in this module. The module adds `Component = \"network\"`."
  type        = map(string)
  default     = {}
}
