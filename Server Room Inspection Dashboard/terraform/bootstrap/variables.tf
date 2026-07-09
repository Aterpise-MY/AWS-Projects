variable "region" {
  description = "AWS region for the remote-state backend."
  type        = string
  default     = "ap-southeast-1"
}

variable "state_bucket_name" {
  description = "Globally-unique S3 bucket name that stores Terraform remote state."
  type        = string
  default     = "mcf-srid-tfstate-022499047467-apse1"
}

variable "lock_table_name" {
  description = "DynamoDB table name used for Terraform state locking."
  type        = string
  default     = "mcf-srid-tfstate-lock"
}
