###############################################################################
# TERRAFORM & PROVIDER CONFIGURATION
#
# Project : AWS Systems Manager — Automated OS Patching
# Company : Meridian Health Partners (revenue-cycle / healthcare)
# Purpose : Patch Baselines + Maintenance Windows + AWS-RunPatchBaseline
#
# Compliance drivers (documented in the project README, not enforced here):
#   SOC 2, HIPAA, PCI-DSS 6.3.3, CIS, internal VM-SLA (Critical CVE <= 7d)
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment before team use to enable remote state.
  # Pre-create the S3 bucket + DynamoDB lock table before `terraform init`.
  #
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "ssm-automated-patching/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"  # partition key must be "LockID" (String)
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "SSM-Automated-Patching"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
