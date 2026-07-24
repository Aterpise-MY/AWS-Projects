variable "region" {
  description = "AWS region every resource in the dev environment is deployed into."
  type        = string
  default     = "ap-southeast-1"
}

variable "owner_email" {
  description = "Email of the resource owner, written to the `Owner` default tag. Set in terraform.tfvars; never commit a real address to the example file."
  type        = string
}

variable "name_prefix" {
  description = "Prefix applied to the name of every resource across all modules."
  type        = string
  default     = "ticketing-dev"
}

variable "cluster_name" {
  description = "EKS cluster name. Also drives the `kubernetes.io/cluster/<name>` subnet discovery tags in the network module, so network and eks must agree on it."
  type        = string
  default     = "ticketing-dev"
}

variable "kubernetes_version" {
  description = "EKS control plane Kubernetes minor version. Verified live as the current default for ap-southeast-1."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the dev VPC. Must be a /16 so the /19 pod subnets fit."
  type        = string
  default     = "10.42.0.0/16"
}

variable "azs" {
  description = "Exactly two availability zones to spread public and private subnets across."
  type        = list(string)
  default     = ["ap-southeast-1a", "ap-southeast-1b"]
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs to CloudWatch. Off by default in dev because flow log ingestion is charged per GB."
  type        = bool
  default     = false
}

variable "enable_interface_endpoints" {
  description = "Create the four interface VPC endpoints (ECR API/DKR, STS, CloudWatch Logs). Default true for the production-shaped posture; set false to save ~$76/month and route that egress through the single NAT Gateway. The free S3 gateway endpoint is always created regardless."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public Kubernetes API endpoint. Narrow to office and CI egress ranges before promoting past dev."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "admin_principal_arns" {
  description = "IAM principal ARNs granted AmazonEKSClusterAdminPolicy through EKS access entries. Set in terraform.tfvars; empty by default so validate needs no account context."
  type        = list(string)
  default     = []
}

variable "node_ami_id" {
  description = "Optional custom worker AMI ID (Packer output). When null, the EKS-optimised AL2023 arm64 AMI is used."
  type        = string
  default     = null
}
