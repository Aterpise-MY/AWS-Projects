variable "name_prefix" {
  description = "Prefix applied to resource names, e.g. mcf-srid-prod."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "Availability zones to span (order maps to the *_subnet_cidrs lists)."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDRs for the public tier, one per AZ (ALB + NAT)."
  type        = list(string)
}

variable "app_subnet_cidrs" {
  description = "CIDRs for the private-app tier, one per AZ (Fargate/Lambda)."
  type        = list(string)
}

variable "data_subnet_cidrs" {
  description = "CIDRs for the private-data tier, one per AZ (RDS)."
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "If true, create one NAT Gateway shared by all private subnets (cost control)."
  type        = bool
  default     = true
}
