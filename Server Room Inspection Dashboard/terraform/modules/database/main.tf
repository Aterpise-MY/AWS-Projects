# ===========================================================================
# database module — private RDS PostgreSQL (Phase 1).
# ---------------------------------------------------------------------------
# Single-AZ, storage-encrypted with the shared CMK, NOT publicly accessible,
# attached to the pre-existing data SG + a DB subnet group over the two
# private-data subnets. Master + app-role passwords are generated here and
# handed back as (sensitive) outputs so the secrets module can populate the
# EXISTING db credentials secret (no second secret is created).
# ===========================================================================

# --------------------------- Generated secrets -----------------------------
# RDS master password. Exclude characters RDS forbids in master passwords
# ('/', '@', '"', space).
resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#%*_-+=.:"
}

# Application login-role password (set on srid_app by the migration Lambda).
resource "random_password" "app" {
  length           = 32
  special          = true
  override_special = "!#%*_-+=.:"
}

# --------------------------- DB subnet group -------------------------------
resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-db-subnets"
  description = "Private-data subnets (2 AZ) for the SRID RDS instance."
  subnet_ids  = var.db_subnet_ids

  tags = {
    Name = "${var.name_prefix}-db-subnets"
    Tier = "private-data"
  }
}

# --------------------------- Parameter group -------------------------------
resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-pg16"
  family      = "postgres16"
  description = "SRID PostgreSQL 16 params: force SSL + query/connection logging."

  # Force TLS for every client connection (static -> applied at (re)boot).
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  # Log statements slower than 1s (dynamic).
  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_connections"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "log_disconnections"
    value        = "1"
    apply_method = "immediate"
  }

  tags = {
    Name = "${var.name_prefix}-pg16"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------- Instance ----------------------------------
resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-pg"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  # Storage — gp3, encrypted with the shared CMK.
  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage > 0 ? var.max_allocated_storage : null
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  # Identity / credentials.
  db_name  = var.db_name
  username = var.master_username
  password = random_password.master.result
  port     = 5432

  # Network — private, single-AZ, data SG + DB subnet group.
  multi_az               = false
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.data_sg_id]
  parameter_group_name   = aws_db_parameter_group.this.name

  # Backups / maintenance.
  backup_retention_period   = var.backup_retention_period
  backup_window             = var.backup_window
  maintenance_window        = var.maintenance_window
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = true
  final_snapshot_identifier = null
  apply_immediately         = true

  # Observability.
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_kms_key_id       = var.performance_insights_enabled ? var.kms_key_arn : null
  performance_insights_retention_period = var.performance_insights_enabled ? 7 : null
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true

  tags = {
    Name = "${var.name_prefix}-pg"
    Tier = "private-data"
  }
}
