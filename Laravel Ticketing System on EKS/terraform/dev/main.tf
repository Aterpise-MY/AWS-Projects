# Root composition for the dev environment.
#
# Wiring order (data flow, not literal file order):
#   network -> eks -> { ecr, database, cache, storage, secrets }
#
# The eks module consumes storage.bucket_arn and the four secret ARNs, while
# database and cache consume eks.node_security_group_id. Terraform resolves this
# at resource granularity (the node security group and the IRSA policy are
# distinct resources), so there is no dependency cycle.

# Account ID is used as the globally-unique attachments-bucket suffix.
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# Networking: VPC, subnets, single NAT gateway, VPC endpoints
# ---------------------------------------------------------------------------
module "network" {
  source = "../modules/network"

  name_prefix                = var.name_prefix
  vpc_cidr                   = var.vpc_cidr
  azs                        = var.azs
  cluster_name               = var.cluster_name
  enable_flow_logs           = var.enable_flow_logs
  enable_interface_endpoints = var.enable_interface_endpoints

  tags = {}
}

# ---------------------------------------------------------------------------
# EKS control plane, node groups, and IRSA roles
# ---------------------------------------------------------------------------
module "eks" {
  source = "../modules/eks"

  name_prefix        = var.name_prefix
  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  public_subnet_ids  = module.network.public_subnet_ids

  node_ami_id         = var.node_ami_id
  public_access_cidrs = var.public_access_cidrs

  # S3 bucket the application IRSA role is scoped to, and nothing else.
  attachments_bucket_arn = module.storage.bucket_arn

  # Every Secrets Manager secret the External Secrets Operator may read:
  # app_key + smtp (secrets module), database (database module), redis (cache).
  secret_arns = concat(
    module.secrets.all_secret_arns,
    [
      module.database.credentials_secret_arn,
      module.cache.auth_token_secret_arn,
    ],
  )

  admin_principal_arns = var.admin_principal_arns

  tags = {}
}

# ---------------------------------------------------------------------------
# ECR: application repo (immutable) + BuildKit cache repo (mutable)
# ---------------------------------------------------------------------------
module "ecr" {
  source = "../modules/ecr"

  name_prefix = var.name_prefix

  # Node roles get pull access through the repository resource policy.
  pull_principal_arns = [
    module.eks.system_node_role_arn,
    module.eks.app_node_role_arn,
  ]

  tags = {}
}

# ---------------------------------------------------------------------------
# RDS MySQL (Single-AZ dev instance)
# ---------------------------------------------------------------------------
module "database" {
  source = "../modules/database"

  name_prefix        = var.name_prefix
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  # Only the EKS worker nodes may reach MySQL. No CIDR ingress.
  allowed_security_group_ids = [module.eks.node_security_group_id]

  tags = {}
}

# ---------------------------------------------------------------------------
# ElastiCache Redis (cache, sessions, queue broker)
# ---------------------------------------------------------------------------
module "cache" {
  source = "../modules/cache"

  name_prefix        = var.name_prefix
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  # Only the EKS worker nodes may reach Redis. No CIDR ingress.
  allowed_security_group_ids = [module.eks.node_security_group_id]

  tags = {}
}

# ---------------------------------------------------------------------------
# S3 bucket for ticket attachments
# ---------------------------------------------------------------------------
module "storage" {
  source = "../modules/storage"

  name_prefix = var.name_prefix
  # Account ID makes the bucket name globally unique and is stable across applies.
  bucket_suffix = data.aws_caller_identity.current.account_id

  tags = {}
}

# ---------------------------------------------------------------------------
# Secrets Manager: Laravel APP_KEY + SMTP placeholder
# (DB and Redis secrets are owned by their own modules)
# ---------------------------------------------------------------------------
module "secrets" {
  source = "../modules/secrets"

  name_prefix = var.name_prefix

  tags = {}
}
