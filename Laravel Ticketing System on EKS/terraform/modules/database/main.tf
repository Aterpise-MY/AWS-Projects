# ---------------------------------------------------------------------------
# RDS for MySQL - ticketing platform primary datastore
#
# The module owns its own credentials end to end: it generates the password,
# writes it to Secrets Manager, and never returns it to the caller. Passing a
# password between modules as a Terraform output would put it in the plan file
# of every consumer, not just this module's state.
# ---------------------------------------------------------------------------

locals {
  tags        = merge(var.tags, { Component = "data" })
  identifier  = "${var.name_prefix}-mysql"
  secret_name = "${var.name_prefix}/database"
}

# ---------------------------------------------------------------------------
# Credentials
#
# RDS for MySQL rejects '/', '"', '@' and space in a master password. The
# override_special set below is the printable-special subset that is safe both
# for RDS and for embedding in a DSN.
# ---------------------------------------------------------------------------

resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"

  # Regenerating the password would replace the instance's credentials out from
  # under running pods; rotation is an explicit, deliberate operation.
  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-db-subnet-group"
  description = "Private subnets for ${local.identifier}"
  subnet_ids  = var.private_subnet_ids

  tags = merge(local.tags, { Name = "${var.name_prefix}-db-subnet-group" })
}

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-db-sg"
  description = "MySQL access for ${local.identifier}"
  vpc_id      = var.vpc_id

  # No egress rules are declared on purpose. A Terraform-managed security group
  # starts with none, and the database has no reason to initiate connections.

  tags = merge(local.tags, { Name = "${var.name_prefix}-db-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "mysql" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "MySQL from ${each.value}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# ---------------------------------------------------------------------------
# Parameter group
#
# Exists so connection tuning is reviewable in code rather than clicked into the
# console. max_connections is left at the engine default, which RDS computes as:
#
#     max_connections = DBInstanceClassMemory / 12582880
#
# On db.t4g.micro (1 GiB) that resolves to roughly 85 usable connections. That
# ceiling is the binding constraint for PHP-FPM sizing: every php-fpm child holds
# its own MySQL connection, so total pods x pm.max_children must stay below it.
# The measured value from SHOW VARIABLES on the live instance is recorded in the
# runbook (docs/) - this comment records the formula, the runbook records reality.
# Set var.max_connections to pin an explicit value instead.
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-mysql-params"
  family      = var.parameter_group_family
  description = "MySQL parameters for ${local.identifier}"

  dynamic "parameter" {
    for_each = var.max_connections == null ? [] : [var.max_connections]

    content {
      name         = "max_connections"
      value        = parameter.value
      apply_method = "pending-reboot"
    }
  }

  parameter {
    name         = "time_zone"
    value        = "UTC"
    apply_method = "immediate"
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-mysql-params" })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------

resource "aws_db_instance" "this" {
  identifier = local.identifier

  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.username
  password = random_password.master.result
  port     = 3306

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false

  multi_az                   = false
  auto_minor_version_upgrade = true
  apply_immediately          = true

  backup_retention_period = var.backup_retention_period
  # UTC windows chosen to sit in the small hours of Asia/Singapore (UTC+8) and
  # not to overlap each other.
  backup_window            = "18:00-19:00"
  maintenance_window       = "sun:19:30-sun:20:30"
  copy_tags_to_snapshot    = true
  delete_automated_backups = true

  # Dev posture: the environment is disposable and recreated from Terraform.
  skip_final_snapshot = true
  deletion_protection = false

  performance_insights_enabled = false
  monitoring_interval          = 0

  tags = merge(local.tags, { Name = local.identifier })

  lifecycle {
    # RDS reports the resolved patch version (for example 8.0.42) while the
    # variable holds "8.0"; without this every plan would show a spurious change.
    ignore_changes = [engine_version]
  }
}

# ---------------------------------------------------------------------------
# Credentials secret
#
# Consumed by the External Secrets Operator, which projects these JSON keys into
# the Laravel environment. The key names are part of the platform contract.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "credentials" {
  name                    = local.secret_name
  description             = "MySQL master credentials and connection details for ${local.identifier}"
  recovery_window_in_days = var.secret_recovery_window_days

  tags = merge(local.tags, { Name = local.secret_name })
}

resource "aws_secretsmanager_secret_version" "credentials" {
  secret_id = aws_secretsmanager_secret.credentials.id

  secret_string = jsonencode({
    username = var.username
    password = random_password.master.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    dbname   = var.db_name
  })
}
