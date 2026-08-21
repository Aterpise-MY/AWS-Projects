variable "region" {
  description = "AWS region to deploy the EKS cluster into."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "gitops-eks"
}

variable "kubernetes_version" {
  description = "Kubernetes control-plane version for the EKS cluster."
  type        = string
  default     = "1.30"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group worker nodes."
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes the group can scale to."
  type        = number
  default     = 4

  validation {
    condition     = var.node_max_size >= var.node_desired_size
    error_message = "node_max_size must be greater than or equal to node_desired_size."
  }
}

variable "argocd_chart_version" {
  description = "Version of the argo-cd Helm chart to install."
  type        = string
  default     = "7.7.5"
}

variable "argocd_namespace" {
  description = "Namespace ArgoCD is installed into."
  type        = string
  default     = "argocd"
}

variable "gitops_repo_url" {
  description = "Git repository URL that ArgoCD watches as the source of truth."
  type        = string
  default     = "https://github.com/argoproj/argocd-example-apps.git"
}

variable "gitops_path" {
  description = "Path within the GitOps repo containing the application manifests."
  type        = string
  default     = "guestbook"
}

variable "gitops_target_revision" {
  description = "Git branch, tag, or commit ArgoCD tracks."
  type        = string
  default     = "HEAD"
}

variable "gitops_dest_namespace" {
  description = "Kubernetes namespace the sample application is deployed into."
  type        = string
  default     = "default"
}

variable "tags" {
  description = "Tags applied to all resources that support them."
  type        = map(string)
  default = {
    Project     = "kubernetes-gitops-argocd"
    Environment = "demo"
    ManagedBy   = "terraform"
    Owner       = "platform-team"
  }
}
