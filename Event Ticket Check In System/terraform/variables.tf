variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix for resource naming and tagging"
  type        = string
  default     = "yrc2027"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "prod"
}

variable "html_credential" {
  description = "Secret credential value that enables HTML+QR email mode in GmailSender Lambda"
  type        = string
  sensitive   = true
}

variable "lambda_runtime" {
  description = "Python runtime version for all Lambda functions"
  type        = string
  default     = "python3.11"
}

# Paths to Lambda source directories — populated from Setup/ before apply
variable "submit_sqs_source_file" {
  description = "Path to SubmitGmailSenderSQS lambda_function.py (relative to terraform/)"
  type        = string
  default     = "../Setup/lambda_function.py"
}

variable "gmail_sender_source_dir" {
  description = "Path to GmailSender source directory (relative to terraform/)"
  type        = string
  default     = "../Setup/GmailSender-6f0f5b36-84fe-4c40-a7ac-36496e077aa8"
}

variable "get_ticket_status_source_dir" {
  description = "Path to GetTicketStatus source directory (relative to terraform/)"
  type        = string
  default     = "../Setup/GetTicketStatus"
}
