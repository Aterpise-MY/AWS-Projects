variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module (for example ticketing-dev)."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used in Kubernetes discovery tags and IRSA trust policies."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane Kubernetes minor version. Verified live against aws eks describe-cluster-versions."
  type        = string
  default     = "1.36"
}

variable "vpc_id" {
  description = "ID of the VPC the cluster and its node groups are deployed into."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs used for the node groups and the cluster ENIs. One per availability zone."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs attached to the cluster so the AWS Load Balancer Controller can place internet-facing ALBs."
  type        = list(string)
}

variable "node_ami_id" {
  description = "Optional custom AMI ID (Packer output) for the worker nodes. When null, the EKS-optimised AL2023 arm64 AMI is used and EKS manages the bootstrap user data."
  type        = string
  default     = null
}

variable "system_instance_type" {
  description = "Instance type for the tainted system node group that hosts cluster add-ons."
  type        = string
  default     = "t4g.small"
}

variable "app_instance_types" {
  description = "Instance types offered to the Spot-backed application node group. Listing several types improves Spot capacity availability."
  type        = list(string)
  default     = ["t4g.medium"]
}

variable "app_min_size" {
  description = "Minimum number of nodes in the application node group."
  type        = number
  default     = 2
}

variable "app_max_size" {
  description = "Maximum number of nodes in the application node group. Upper bound for Cluster Autoscaler."
  type        = number
  default     = 4
}

variable "app_desired_size" {
  description = "Initial desired number of nodes in the application node group. Ignored after creation so Cluster Autoscaler owns it."
  type        = number
  default     = 2
}

variable "attachments_bucket_arn" {
  description = "ARN of the S3 bucket holding ticket attachments. The app IRSA role is granted access to this bucket and nothing else."
  type        = string
}

variable "secret_arns" {
  description = "Secrets Manager secret ARNs the External Secrets Operator is allowed to read. Composed by the root module from every secret-owning module."
  type        = list(string)
  default     = []
}

variable "admin_principal_arns" {
  description = "IAM principal ARNs granted AmazonEKSClusterAdminPolicy through EKS access entries. The aws-auth ConfigMap is never managed by this module."
  type        = list(string)
  default     = []
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public Kubernetes API endpoint. Narrow this to the office and CI egress ranges before promoting past dev."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_volume_size" {
  description = "Size in GiB of the encrypted gp3 root volume attached to every worker node."
  type        = number
  default     = 20
}

variable "log_retention_days" {
  description = "Retention in days for the EKS control plane CloudWatch log group. Created explicitly so it never falls back to never-expire."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Base tags inherited from the root module. The module merges Component = compute on top of these."
  type        = map(string)
  default     = {}
}
