###############################################################################
# TERRAFORM & PROVIDER CONFIGURATION
#
# Project : GitHub Actions CI/CD -> AWS ECS (Fargate)
# Company : Northwind Commerce (e-commerce storefront API)
# Purpose : ECR + ECS Fargate service behind an ALB, deployed continuously
#           from GitHub Actions on every push to main.
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
  #   key            = "github-actions-ecs/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"  # partition key must be "LockID" (String)
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "GitHub-Actions-ECS"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}
