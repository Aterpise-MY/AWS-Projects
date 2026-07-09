# ---------------------------------------------------------------------------
# cognito module inputs — Phase 4 authentication.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Resource name prefix (e.g. mcf-srid-prod)."
  type        = string
}

variable "region" {
  description = "AWS region (for the hosted-UI URL)."
  type        = string
}

variable "domain" {
  description = "Cognito hosted-UI domain PREFIX. Globally unique across AWS; defaults to name_prefix when empty."
  type        = string
  default     = ""
}

variable "callback_urls" {
  description = "OAuth callback URLs. Must be non-empty before apply once the ALB HTTPS URL is known."
  type        = list(string)
  default     = []
}

variable "alb_listener_arn" {
  description = "HTTPS listener ARN the authenticate-cognito rule attaches to (nullable — only used when enable_alb_auth && alb_https_enabled)."
  type        = string
  default     = null
}

variable "target_group_arn" {
  description = "Target group ARN the auth rule forwards to after authentication (nullable)."
  type        = string
  default     = null
}

variable "alb_https_enabled" {
  description = "Whether the ALB has an HTTPS listener. ALB Cognito auth REQUIRES HTTPS."
  type        = bool
  default     = false
}

variable "enable_alb_auth" {
  description = "Create the ALB authenticate-cognito listener rule. Only takes effect with alb_https_enabled."
  type        = bool
  default     = false
}
