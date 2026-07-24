provider "aws" {
  region = var.region

  # Applied to every taggable resource in every module. `Component` is
  # deliberately NOT set here: it varies per module (network, compute, registry,
  # data, ...) and each module merges its own value on top of these.
  default_tags {
    tags = {
      Project     = "ticketing"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = var.owner_email
      Repository  = "github.com/brendonang/ticketing-platform"
      AutoDelete  = "true"
    }
  }
}
