# ---------------------------------------------------------------------------
# Security module — baseline least-privilege security groups.
#
# Chain (wired by SG reference, not CIDRs):
#   Internet --443--> ALB SG --app_port--> App/Fargate SG --5432--> Data SG
#
# These are the security foundation; later phases attach ENIs (ALB, Fargate
# tasks, RDS) to the matching SG. Rules use the split
# aws_vpc_security_group_(ingress|egress)_rule resources (provider v5 style).
# ---------------------------------------------------------------------------

# ------------------------------- ALB SG ------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "ALB ingress from internet on 443; egress to app tier"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-alb-sg"
    Tier = "public"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Phase 3 demo: plain-HTTP ingress on the ALB. Gated so it can be disabled once
# HTTPS-only is the posture. NARROW office_cidr for real data (unauthenticated).
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count             = var.enable_http_ingress ? 1 : 0
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from office CIDR (Phase 3 demo)"
  ip_protocol       = "tcp"
  from_port         = var.http_port
  to_port           = var.http_port
  cidr_ipv4         = var.office_cidr
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward to app tier on app port"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.app.id
}

# ------------------------------- App SG ------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "App/Fargate tier: ingress from ALB only; egress anywhere (NAT)"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-app-sg"
    Tier = "private-app"
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "App port from ALB SG"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

# App tier needs outbound to the internet (via NAT) for image pulls, AWS API
# calls, AppFlow, SES, etc. Egress to the DB is additionally allowed below.
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound (NAT egress)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ------------------------------ Data SG ------------------------------------
resource "aws_security_group" "data" {
  name        = "${var.name_prefix}-data-sg"
  description = "Data tier (RDS PostgreSQL): ingress 5432 from app SG only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.name_prefix}-data-sg"
    Tier = "private-data"
  }
}

resource "aws_vpc_security_group_ingress_rule" "data_from_app" {
  security_group_id            = aws_security_group.data.id
  description                  = "PostgreSQL from app SG"
  ip_protocol                  = "tcp"
  from_port                    = var.db_port
  to_port                      = var.db_port
  referenced_security_group_id = aws_security_group.app.id
}

# No egress rules needed for RDS; a minimal self-egress placeholder keeps the
# DB from having the implicit allow-all egress. Restrict to VPC CIDR.
resource "aws_vpc_security_group_egress_rule" "data_vpc_only" {
  security_group_id = aws_security_group.data.id
  description       = "Restrict DB egress to VPC CIDR"
  ip_protocol       = "-1"
  cidr_ipv4         = var.vpc_cidr
}
