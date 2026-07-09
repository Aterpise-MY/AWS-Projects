# ===========================================================================
# cognito module — Phase 4 authentication (deploy-ready).
# ---------------------------------------------------------------------------
# Provisions a Cognito user pool, hosted-UI domain, and an app client wired for
# the OIDC authorization-code flow, ready to front the dashboard. The actual
# ALB integration (authenticate-cognito listener rule) is count-gated because
# ALB Cognito authentication REQUIRES an HTTPS listener; the Phase 3 demo runs
# plain HTTP:80, so it stays OFF until an ACM cert + HTTPS listener exist.
#
# Users are admin-created only (no self sign-up) per the enterprise scenario.
# ===========================================================================

locals {
  # Hosted-UI domain prefixes are globally unique across all AWS accounts.
  domain_prefix = var.domain != "" ? var.domain : var.name_prefix
}

resource "aws_cognito_user_pool" "this" {
  name = var.name_prefix

  # Email is the sign-in identifier.
  alias_attributes         = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # MFA available but not forced (TOTP). Facilities staff opt in.
  mfa_configuration = "OPTIONAL"
  software_token_mfa_configuration {
    enabled = true
  }

  # No public sign-up — an admin invites each MCF facilities user.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = { Name = var.name_prefix }
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = local.domain_prefix
  user_pool_id = aws_cognito_user_pool.this.id
}

resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.name_prefix}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret                      = true
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls                        = var.callback_urls
  supported_identity_providers         = ["COGNITO"]

  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]
}

# ---------------------------------------------------------------------------
# ALB authenticate-cognito listener rule.
#
# HTTPS PREREQUISITE: ALB Cognito authentication only works on an HTTPS (TLS)
# listener. This rule therefore materialises ONLY when both flags are set:
#   enable_alb_auth = true  AND  alb_https_enabled = true
# i.e. after an ACM certificate + HTTPS listener are in place (PHASE3 Path A).
# It stays disabled for the HTTP:80 demo.
# ---------------------------------------------------------------------------
resource "aws_lb_listener_rule" "cognito_auth" {
  count        = var.enable_alb_auth && var.alb_https_enabled ? 1 : 0
  listener_arn = var.alb_listener_arn
  priority     = 10

  action {
    type = "authenticate-cognito"

    authenticate_cognito {
      user_pool_arn       = aws_cognito_user_pool.this.arn
      user_pool_client_id = aws_cognito_user_pool_client.this.id
      user_pool_domain    = aws_cognito_user_pool_domain.this.domain
    }
  }

  action {
    type             = "forward"
    target_group_arn = var.target_group_arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}
