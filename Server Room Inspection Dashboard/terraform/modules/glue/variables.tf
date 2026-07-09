variable "name_prefix" {
  description = "Resource name prefix."
  type        = string
}

variable "account_id" {
  description = "AWS account ID (for bucket naming)."
  type        = string
}

variable "region_short" {
  description = "Short region token for bucket naming (e.g. apse1)."
  type        = string
  default     = "apse1"
}

variable "region" {
  description = "AWS region."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID (for the Glue security group)."
  type        = string
}

variable "glue_subnet_id" {
  description = "Private-app subnet ID for the Glue connection ENIs (has NAT)."
  type        = string
}

variable "availability_zone" {
  description = "AZ of glue_subnet_id (required by the Glue connection)."
  type        = string
}

variable "data_sg_id" {
  description = "Data-tier SG ID; a rule is added allowing 5432 from the Glue SG."
  type        = string
}

variable "db_secret_arn" {
  description = "ARN of the db credentials secret the Glue job reads."
  type        = string
}

variable "kms_key_arn" {
  description = "CMK ARN for bucket SSE + secret decrypt."
  type        = string
}

variable "db_port" {
  description = "RDS port the Glue SG must reach."
  type        = number
  default     = 5432
}

variable "script_local_path" {
  description = "Local path to the Glue job script uploaded to the bucket."
  type        = string
}

variable "csv_local_path" {
  description = "Local path to the synthetic backfill CSV uploaded to the bucket."
  type        = string
}

variable "backfill_key" {
  description = "S3 key for the uploaded backfill CSV."
  type        = string
  default     = "raw/backfill_inspections.csv"
}
