variable "name_prefix" {
  description = "Prefix for the bucket name, e.g. `ticketing-dev`."
  type        = string
}

variable "bucket_suffix" {
  description = "Suffix appended to the bucket name to make it globally unique, typically the AWS account ID or a random string. Final name is `<name_prefix>-attachments-<bucket_suffix>`."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.bucket_suffix))
    error_message = "bucket_suffix must be lowercase alphanumeric or hyphens, and must not start or end with a hyphen."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Days a noncurrent object version is retained before permanent deletion."
  type        = number
  default     = 7

  validation {
    condition     = var.noncurrent_version_expiration_days >= 1
    error_message = "noncurrent_version_expiration_days must be at least 1."
  }
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Days after which incomplete multipart uploads are aborted and their parts deleted."
  type        = number
  default     = 7
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete the bucket together with all objects and versions it contains. True for this dev environment."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Base tags merged into every resource in this module. The module adds `Component = \"data\"`."
  type        = map(string)
  default     = {}
}
