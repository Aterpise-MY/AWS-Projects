variable "name_prefix" {
  description = "Prefix for the Secrets Manager secret names, e.g. `ticketing-dev`. Produces `ticketing-dev/app-key` and `ticketing-dev/smtp`, which External Secrets and the Helm chart reference verbatim."
  type        = string
}

variable "recovery_window_in_days" {
  description = "Secrets Manager recovery window on delete. 0 deletes immediately, which is required in dev so a destroy/apply cycle can reuse the same secret names instead of colliding with a scheduled-for-deletion secret."
  type        = number
  default     = 0

  validation {
    condition     = var.recovery_window_in_days == 0 || (var.recovery_window_in_days >= 7 && var.recovery_window_in_days <= 30)
    error_message = "recovery_window_in_days must be 0 (immediate delete) or between 7 and 30."
  }
}

variable "smtp_placeholder_host" {
  description = "Placeholder SMTP host written on first apply. Not a credential; the real value is set out-of-band and preserved by ignore_changes."
  type        = string
  default     = "smtp.example.invalid"
}

variable "smtp_placeholder_port" {
  description = "Placeholder SMTP port written on first apply."
  type        = number
  default     = 587
}

variable "smtp_placeholder_encryption" {
  description = "Placeholder SMTP transport encryption written on first apply, e.g. `tls` or `ssl`."
  type        = string
  default     = "tls"
}

variable "smtp_placeholder_from_address" {
  description = "Placeholder From address written on first apply."
  type        = string
  default     = "no-reply@example.invalid"
}

variable "tags" {
  description = "Base tags merged into every resource in this module. The module adds `Component = \"data\"`."
  type        = map(string)
  default     = {}
}
