# ---------------------------------------------------------------------------
# AWS provider + org-wide default tagging strategy.
# default_tags are applied to every taggable resource created by this config,
# so individual resources only add a `Name` (and occasionally `Tier`).
# ---------------------------------------------------------------------------
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = "MCF-Facilities"
      CostCenter  = var.cost_center
      Application = "ServerRoomInspectionDashboard"
    }
  }
}
