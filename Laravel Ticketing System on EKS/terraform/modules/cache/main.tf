# ---------------------------------------------------------------------------
# ElastiCache for Redis - cache, session store and queue broker
#
# Redis logical database index assignment (mirrored in the Helm values, the
# Laravel config and the runbook - all four must agree):
#
#   ┌───────┬────────────┬──────────────────────────────────┐
#   │ Index │ Role       │ Laravel setting                  │
#   ├───────┼────────────┼──────────────────────────────────┤
#   │   0   │ Cache      │ REDIS_CACHE_DB=0                 │
#   │   1   │ Sessions   │ session store connection         │
#   │   2   │ Queue      │ REDIS_QUEUE_DB=2                 │
#   └───────┴────────────┴──────────────────────────────────┘
#
# Separating them matters: `php artisan cache:clear` issues FLUSHDB, which on a
# shared index would also destroy every queued job and every logged-in session.
#
# Like the database module, this module owns its own credential end to end and
# never returns the AUTH token to the caller.
# ---------------------------------------------------------------------------

locals {
  tags              = merge(var.tags, { Component = "data" })
  replication_group = "${var.name_prefix}-redis"
  secret_name       = "${var.name_prefix}/redis-auth"
}

# ---------------------------------------------------------------------------
# AUTH token
#
# ElastiCache accepts 16-128 printable characters but rejects '/', '"' and '@'.
# The override_special set below omits all three; leaving them in produces a
# CacheClusterAlreadyExists-style failure only at apply time, well after the
# replication group has started provisioning.
# ---------------------------------------------------------------------------

resource "random_password" "auth_token" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"

  lifecycle {
    ignore_changes = [length, special, override_special]
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

resource "aws_elasticache_subnet_group" "this" {
  name        = "${var.name_prefix}-cache-subnet-group"
  description = "Private subnets for ${local.replication_group}"
  subnet_ids  = var.private_subnet_ids

  tags = merge(local.tags, { Name = "${var.name_prefix}-cache-subnet-group" })
}

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-cache-sg"
  description = "Redis access for ${local.replication_group}"
  vpc_id      = var.vpc_id

  # No egress rules by design - the cache never initiates outbound connections.

  tags = merge(local.tags, { Name = "${var.name_prefix}-cache-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "redis" {
  for_each = toset(var.allowed_security_group_ids)

  security_group_id            = aws_security_group.this.id
  description                  = "Redis from ${each.value}"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = var.port
  to_port                      = var.port
}

# ---------------------------------------------------------------------------
# Replication group
#
# Cluster mode disabled with a single node: Laravel's queue driver and session
# handler both assume a single logical keyspace, and cluster mode would shard
# the queue keys across slots. Single node also means no failover - acceptable
# for dev, called out in the README as the first thing to change for production.
# ---------------------------------------------------------------------------

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = local.replication_group
  description          = "Redis cache, sessions and queue broker for ${var.name_prefix}"

  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  parameter_group_name = var.parameter_group_name
  port                 = var.port

  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.auth_token.result
  auth_token_update_strategy = "ROTATE"

  # No snapshots: everything in Redis is either regenerable cache, a session, or
  # a queued job that the application is expected to be able to lose in dev.
  snapshot_retention_limit = 0

  auto_minor_version_upgrade = true
  apply_immediately          = true
  # UTC window, i.e. the small hours of Asia/Singapore (UTC+8).
  maintenance_window = "sun:20:30-sun:21:30"

  tags = merge(local.tags, { Name = local.replication_group })

  lifecycle {
    # ElastiCache reports the resolved patch version (for example 7.1.0) while
    # the variable holds "7.1".
    ignore_changes = [engine_version]
  }
}

# ---------------------------------------------------------------------------
# AUTH token secret
#
# JSON keys consumed by the External Secrets Operator and projected into the
# Laravel environment. `scheme` is tls because transit encryption is on: a plain
# redis:// DSN against this endpoint fails the handshake with a bare
# "Connection reset by peer" and no TLS-specific error.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "auth_token" {
  name                    = local.secret_name
  description             = "Redis AUTH token and connection details for ${local.replication_group}"
  recovery_window_in_days = var.secret_recovery_window_days

  tags = merge(local.tags, { Name = local.secret_name })
}

resource "aws_secretsmanager_secret_version" "auth_token" {
  secret_id = aws_secretsmanager_secret.auth_token.id

  secret_string = jsonencode({
    host     = aws_elasticache_replication_group.this.primary_endpoint_address
    port     = var.port
    password = random_password.auth_token.result
    scheme   = "tls"
  })
}
