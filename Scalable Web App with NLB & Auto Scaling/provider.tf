terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Uncomment the block below before team use to enable remote state.
  # Pre-create the S3 bucket and DynamoDB table before running terraform init.
  #
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "scalable-webapp/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"  # partition key must be "LockID" (String)
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
