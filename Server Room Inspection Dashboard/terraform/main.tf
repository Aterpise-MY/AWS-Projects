# ===========================================================================
# MCF Server Room Inspection Dashboard — Phase 0 (Foundations)
# ---------------------------------------------------------------------------
# Deploys the shared network, encryption, IAM, security-group, and secret
# foundations that later phases (RDS, ECS/Fargate, ALB, Lambda, AppFlow,
# Cognito, SES, EventBridge, Glue, CloudWatch) attach to.
#
# Phase 0 does NOT create: RDS, ECS/ALB/Lambda compute, Cognito, AD Connector,
# or any application data. Those are gated on Boss confirmation per phase.
# ===========================================================================

locals {
  # Standard resource name prefix, e.g. "mcf-srid-prod".
  name_prefix = "${var.project}-${var.environment}"

  # First AZ (and its private-app subnet) hosts the Glue connection ENIs.
  glue_az        = var.availability_zones[0]
  glue_subnet_id = module.networking.app_subnets_by_az[var.availability_zones[0]]
}

data "aws_caller_identity" "current" {}

# --------------------------- Networking ------------------------------------
module "networking" {
  source = "./modules/networking"

  name_prefix         = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  availability_zones  = var.availability_zones
  public_subnet_cidrs = var.public_subnet_cidrs
  app_subnet_cidrs    = var.app_subnet_cidrs
  data_subnet_cidrs   = var.data_subnet_cidrs
  single_nat_gateway  = var.single_nat_gateway
}

# ------------------------------- KMS ---------------------------------------
module "kms" {
  source = "./modules/kms"

  name_prefix = local.name_prefix
  region      = var.region
  alias_name  = var.kms_alias
}

# ------------------------- Security groups ---------------------------------
module "security" {
  source = "./modules/security"

  name_prefix = local.name_prefix
  vpc_id      = module.networking.vpc_id
  vpc_cidr    = module.networking.vpc_cidr
  app_port    = var.app_port
  db_port     = var.db_port

  # Phase 3 demo: plain-HTTP ingress on the ALB SG (narrow office_cidr for prod).
  enable_http_ingress = var.enable_http_ingress
  http_port           = var.alb_listener_port
  office_cidr         = var.office_cidr
}

# ------------------------------- IAM ---------------------------------------
module "iam" {
  source = "./modules/iam"

  name_prefix = local.name_prefix
}

# ---------------------------- Secrets --------------------------------------
module "secrets" {
  source = "./modules/secrets"

  name_prefix = local.name_prefix
  kms_key_arn = module.kms.key_arn

  # Phase 1: populate the EXISTING db secret placeholder with real RDS creds.
  db_connection = module.database.db_connection
}

# ===========================================================================
# Phase 1 — Database
# ===========================================================================

# ------------------------------- RDS ---------------------------------------
module "database" {
  source = "./modules/database"

  name_prefix   = local.name_prefix
  db_subnet_ids = module.networking.data_subnet_ids
  data_sg_id    = module.security.data_sg_id
  kms_key_arn   = module.kms.key_arn

  engine_version = var.db_engine_version
  instance_class = var.db_instance_class
  db_name        = var.db_name
}

# ===========================================================================
# Phase 2 — Ingestion (migration Lambda + Glue backfill)
# ===========================================================================

# ------------------------- Migration Lambda --------------------------------
module "migration" {
  source = "./modules/migration"

  name_prefix        = local.name_prefix
  subnet_ids         = module.networking.app_subnet_ids
  security_group_ids = [module.security.app_sg_id]
  db_secret_arn      = module.secrets.db_secret_arn
  kms_key_arn        = module.kms.key_arn
  package_path       = "${path.module}/modules/migration/dist/migration.zip"
}

# --------------------------- Glue backfill ---------------------------------
module "glue" {
  source = "./modules/glue"

  name_prefix       = local.name_prefix
  account_id        = data.aws_caller_identity.current.account_id
  region            = var.region
  vpc_id            = module.networking.vpc_id
  glue_subnet_id    = local.glue_subnet_id
  availability_zone = local.glue_az
  data_sg_id        = module.security.data_sg_id
  db_secret_arn     = module.secrets.db_secret_arn
  kms_key_arn       = module.kms.key_arn

  script_local_path = "${path.module}/../database/glue/backfill_job.py"
  csv_local_path    = "${path.module}/../database/glue/data/backfill_inspections.csv"
}

# ===========================================================================
# Phase 3 — Dashboard compute (ECS Fargate + ALB + ECR)
# ===========================================================================
module "compute" {
  source = "./modules/compute"

  name_prefix = local.name_prefix
  region      = var.region
  account_id  = data.aws_caller_identity.current.account_id

  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
  app_subnet_ids    = module.networking.app_subnet_ids
  app_sg_id         = module.security.app_sg_id
  alb_sg_id         = module.security.alb_sg_id

  kms_key_arn   = module.kms.key_arn
  db_secret_arn = module.secrets.db_secret_arn

  ecs_task_execution_role_arn  = module.iam.ecs_task_execution_role_arn
  ecs_task_execution_role_name = module.iam.ecs_task_execution_role_name
  ecs_task_role_arn            = module.iam.ecs_task_role_arn
  ecs_task_role_name           = module.iam.ecs_task_role_name

  app_port           = var.app_port
  container_cpu      = var.container_cpu
  container_memory   = var.container_memory
  desired_count      = var.desired_count
  log_retention_days = var.log_retention_days
  image_tag          = var.image_tag
  alb_listener_port  = var.alb_listener_port
}

# ===========================================================================
# Phase 4 — Authentication (Cognito). ALB auth gated on HTTPS.
# ===========================================================================
module "cognito" {
  source = "./modules/cognito"

  name_prefix = local.name_prefix
  region      = var.region

  domain        = var.cognito_domain_prefix
  callback_urls = var.cognito_callback_urls

  # ALB authenticate-cognito rule only builds with an HTTPS listener present.
  alb_listener_arn  = module.compute.alb_listener_arn
  target_group_arn  = module.compute.target_group_arn
  alb_https_enabled = var.alb_https_enabled
  enable_alb_auth   = var.enable_cognito_alb_auth
}

# ===========================================================================
# Phase 5 — Breach notifications (SES + EventBridge + Lambda). Gated OFF.
# ===========================================================================
module "notifications" {
  source = "./modules/notifications"

  name_prefix = local.name_prefix
  region      = var.region

  enable_notifications = var.enable_notifications
  sender_email         = var.ses_sender_email
  recipient_emails     = var.ses_recipient_emails
  schedule_expression  = var.notification_schedule

  subnet_ids         = module.networking.app_subnet_ids
  security_group_ids = [module.security.app_sg_id]
  db_secret_arn      = module.secrets.db_secret_arn
  kms_key_arn        = module.kms.key_arn

  lambda_execution_role_arn  = module.iam.lambda_execution_role_arn
  lambda_execution_role_name = module.iam.lambda_execution_role_name
}

# ===========================================================================
# Phase 6 — Observability (CloudWatch) + AD Connector (gated OFF).
# ===========================================================================
module "observability" {
  source = "./modules/observability"

  name_prefix = local.name_prefix
  region      = var.region

  alb_arn_suffix          = module.compute.alb_arn_suffix
  target_group_arn_suffix = module.compute.target_group_arn_suffix
  ecs_cluster_name        = module.compute.ecs_cluster_name
  ecs_service_name        = module.compute.ecs_service_name
  db_instance_id          = module.database.db_instance_id

  alarm_email = var.alarm_email

  # AD Connector — deploy-ready but OFF (needs on-prem VPN + populated secret).
  enable_ad_connector = var.enable_ad_connector
  ad_directory_name   = var.ad_directory_name
  ad_dns_ips          = var.ad_dns_ips
  ad_vpc_id           = module.networking.vpc_id
  ad_subnet_ids       = length(var.ad_subnet_ids) > 0 ? var.ad_subnet_ids : module.networking.app_subnet_ids
  ad_bind_secret_arn  = module.secrets.ad_bind_secret_arn
}
