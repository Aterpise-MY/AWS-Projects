variable "aws_region" {
  description = "AWS region in which the Terraform state bucket, lock table and KMS key are created."
  type        = string
  default     = "ap-southeast-1"
}

variable "name_prefix" {
  description = "Prefix applied to every bootstrap resource name (bucket, lock table, KMS alias)."
  type        = string
  default     = "ticketing-dev"
}

variable "owner_email" {
  description = "Email address recorded in the Owner tag on every bootstrap resource."
  type        = string
  default     = "hengga1007@gmail.com"
}

variable "kms_deletion_window_days" {
  description = "Waiting period, in days, before the state-encryption KMS key is deleted after destroy."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_deletion_window_days >= 7 && var.kms_deletion_window_days <= 30
    error_message = "kms_deletion_window_days must be between 7 and 30."
  }
}

variable "force_destroy_state_bucket" {
  description = "Allow `terraform destroy` to delete the state bucket even when it still contains object versions. Keep false in anything long-lived."
  type        = bool
  default     = false
}
