terraform {
  # EKS module uses provider-defined functions and modern schema features that
  # require Terraform 1.9.0 or newer.
  required_version = ">= 1.9.0"

  required_providers {
    # AWS 6.x is the working floor for every module; 5.90 is the absolute floor
    # some modules declare. Pinning `< 7.0` keeps the whole tree on one major.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.90, < 7.0"
    }
    # random_password backs the DB master credential and the Redis AUTH token.
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    # tls builds the OIDC thumbprint for IRSA in the eks module.
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }
}
