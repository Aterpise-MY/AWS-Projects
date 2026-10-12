###############################################################################
# Provider configuration
#
# Project: MekarMart POS transaction pipeline with dead-letter queues
# Scenario: Enterprise_DLQ_Scenario_POS_EN.md
#
# State is LOCAL for this lab. No S3 backend block is declared, so
# `terraform init -backend=false` and `terraform init` both work against
# `terraform.tfstate` in this directory. Never commit that file.
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Applied to every taggable resource in the stack, including those created
  # inside module "consumer_queue". Per-resource `tags` blocks add Name,
  # Service and QueueRole on top of these.
  default_tags {
    tags = merge(
      {
        Project     = "pos-dlq-pipeline"
        Owner       = "brendon"
        Environment = "lab"
        ManagedBy   = "Terraform"
      },
      var.additional_tags,
    )
  }
}

# Read-only lookup used to surface the target account in outputs without
# hardcoding it. A DLQ must live in the same account and region as its source
# queue, so this is worth asserting at plan time.
data "aws_caller_identity" "current" {}
