/**
 * Project CORTEX - AWS Provider Configuration
 * 
 * Configures the AWS provider with region and default tags
 * for resource management and cost tracking.
 *
 * Provider aliases:
 *   - default (us-east-1): Lambda, API Gateway, EventBridge
 *   - aws.amplify_region (us-east-2): Amplify app's EventBridge events
 */

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      System      = "CORTEX-ChatOps"
    }
  }
}

# Secondary provider for Amplify region (us-east-2)
# Required because Amplify emits EventBridge events in the region where the app lives
provider "aws" {
  alias  = "amplify_region"
  region = var.amplify_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "Terraform"
      System      = "CORTEX-ChatOps"
    }
  }
}
