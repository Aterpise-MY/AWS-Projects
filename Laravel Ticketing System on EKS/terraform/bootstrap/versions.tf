terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Intentionally LOCAL state. This stack creates the remote-state backend
  # itself, so it cannot store its own state there (chicken-and-egg).
  # Commit `terraform.tfstate` for this stack only if the team accepts that it
  # contains no secrets — it holds bucket/table/KMS identifiers only.
}
