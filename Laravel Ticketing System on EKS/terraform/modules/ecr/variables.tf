variable "name_prefix" {
  description = "Prefix applied to the Name tag of the ECR repositories, e.g. `ticketing-dev`."
  type        = string
}

variable "repository_name" {
  description = "Name of the application image repository. Holds the immutable, SHA-tagged runtime images."
  type        = string
  default     = "ticketing/app"
}

variable "cache_repository_name" {
  description = "Name of the BuildKit registry cache repository. Holds `--cache-to`/`--cache-from` layer manifests, not runnable images."
  type        = string
  default     = "ticketing/app-cache"
}

variable "pull_principal_arns" {
  description = "IAM role ARNs granted pull access through the repository resource policy, typically the EKS node role ARNs. An empty list skips the repository policy entirely."
  type        = list(string)
  default     = []
}

variable "untagged_expiry_days" {
  description = "Days after which untagged images in the application repository are expired."
  type        = number
  default     = 1
}

variable "tagged_image_count" {
  description = "Number of most-recent tagged images retained in the application repository."
  type        = number
  default     = 10
}

variable "cache_untagged_expiry_days" {
  description = "Days after which untagged BuildKit cache manifests are expired from the cache repository."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Base tags merged into every resource in this module. The module adds `Component = \"registry\"`."
  type        = map(string)
  default     = {}
}
