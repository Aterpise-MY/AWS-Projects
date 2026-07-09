variable "name_prefix" {
  description = "Prefix applied to SG names."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR (used to scope data-tier egress)."
  type        = string
}

variable "app_port" {
  description = "Port the app/Fargate service listens on."
  type        = number
  default     = 8080
}

variable "db_port" {
  description = "Database port (PostgreSQL)."
  type        = number
  default     = 5432
}

variable "enable_http_ingress" {
  description = "Add a plain-HTTP ingress rule to the ALB SG for the Phase 3 demo. The 443 rule is always kept."
  type        = bool
  default     = true
}

variable "http_port" {
  description = "ALB HTTP listener port for the demo ingress rule."
  type        = number
  default     = 80
}

variable "office_cidr" {
  description = "CIDR allowed to reach the ALB over HTTP. Defaults to 0.0.0.0/0 for the demo; NARROW this to the MCF office egress CIDR because Phase 3 ships unauthenticated."
  type        = string
  default     = "0.0.0.0/0"
}
