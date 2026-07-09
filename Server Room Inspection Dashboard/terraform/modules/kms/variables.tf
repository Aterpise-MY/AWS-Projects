variable "name_prefix" {
  description = "Prefix applied to the key description and tags."
  type        = string
}

variable "region" {
  description = "AWS region (used to scope the CloudWatch Logs service principal)."
  type        = string
}

variable "alias_name" {
  description = "KMS alias, e.g. alias/mcf-srid."
  type        = string
  default     = "alias/mcf-srid"
}

variable "deletion_window_in_days" {
  description = "Waiting period before key deletion (7-30)."
  type        = number
  default     = 30
}
