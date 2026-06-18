# ================================================================
# Multi-Tenant SaaS Application — Terraform Configuration
# Provider: hashicorp/aws ~> 5.0
# ================================================================

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "dnd-terraform-state-staging-022499047467"
    key            = "multitenant-saas/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "cortex-terraform-locks"
  }
}

provider "aws" {
  region = var.region
}

data "aws_region" "current" {}

# ─────────────────────────────────────────────────────────────
# Lambda deployment packages (created by Terraform for consistency)
# ─────────────────────────────────────────────────────────────
data "archive_file" "users_handler" {
  type             = "zip"
  source_dir       = "${path.module}/../lambda/users_handler"
  output_path      = "${path.module}/../lambda/users_handler.zip"
  output_file_mode = "0666"
}

data "archive_file" "orders_handler" {
  type             = "zip"
  source_dir       = "${path.module}/../lambda/orders_handler"
  output_path      = "${path.module}/../lambda/orders_handler.zip"
  output_file_mode = "0666"
}

data "archive_file" "auth_handler" {
  type             = "zip"
  source_dir       = "${path.module}/../lambda/auth_handler"
  output_path      = "${path.module}/../lambda/auth_handler.zip"
  output_file_mode = "0666"
}

locals {
  tags = merge(var.common_tags, { Environment = var.environment_name })
}

# ─────────────────────────────────────────────────────────────
# Cognito User Pool
# ─────────────────────────────────────────────────────────────
resource "aws_cognito_user_pool" "main" {
  name = "saas-user-pool"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length                   = 8
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # Custom attribute for tenant isolation — readable from JWT claims
  schema {
    name                = "tenant_id"
    attribute_data_type = "String"
    mutable             = true
    required            = false
    string_attribute_constraints {
      min_length = "1"
      max_length = "256"
    }
  }

  tags = merge(local.tags, { Name = "saas-user-pool" })
}

resource "aws_cognito_user_pool_client" "main" {
  name         = "saas-app-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false # SPA / mobile — no server-side secret

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "saas-app-prod"
  user_pool_id = aws_cognito_user_pool.main.id
}

# ─────────────────────────────────────────────────────────────
# Secrets Manager — RDS master password
# ─────────────────────────────────────────────────────────────
resource "aws_secretsmanager_secret" "db_password" {
  name        = "saas/db/password"
  description = "RDS master password for Multi-Tenant SaaS"

  tags = merge(local.tags, { Name = "saas-db-password" })
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}

# ─────────────────────────────────────────────────────────────
# Security Groups
# ─────────────────────────────────────────────────────────────
resource "aws_security_group" "lambda" {
  name        = "saas-lambda-sg"
  description = "Outbound-only SG for SaaS Lambda functions"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound (RDS, Secrets Manager, CloudWatch)"
  }

  tags = merge(local.tags, { Name = "saas-lambda-sg" })
}

resource "aws_security_group" "rds" {
  name        = "saas-rds-sg"
  description = "PostgreSQL 5432 inbound from Lambda SG only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
    description     = "PostgreSQL from saas-lambda-sg"
  }

  tags = merge(local.tags, { Name = "saas-rds-sg" })
}

# ─────────────────────────────────────────────────────────────
# RDS — DB Subnet Group + PostgreSQL 15 instance
# ─────────────────────────────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name        = "saas-db-subnet-group"
  description = "Private subnets for SaaS RDS (Multi-AZ)"
  subnet_ids  = var.private_subnet_ids

  tags = merge(local.tags, { Name = "saas-db-subnet-group" })
}

resource "aws_db_instance" "main" {
  identifier        = "saas-postgres"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "saasdb"
  username = "saasadmin"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az                  = var.multi_az
  deletion_protection       = true
  backup_retention_period   = 7
  skip_final_snapshot       = false
  final_snapshot_identifier = "saas-postgres-final-snapshot"
  publicly_accessible       = false
  storage_encrypted         = true

  tags = merge(local.tags, { Name = "saas-postgres" })

  # Secret must exist before RDS is created so Lambda can read it at cold-start
  depends_on = [aws_secretsmanager_secret_version.db_password]
}

# ─────────────────────────────────────────────────────────────
# IAM Role for Lambda
# ─────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "saas-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json

  tags = merge(local.tags, { Name = "saas-lambda-role" })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.db_password.arn]
  }
}

resource "aws_iam_role_policy" "lambda_secrets" {
  name   = "saas-lambda-secrets-access"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_secrets.json
}

# ─────────────────────────────────────────────────────────────
# CloudWatch Log Groups — explicit retention prevents unbounded log storage cost.
# Lambda auto-creates /aws/lambda/<name> if absent, but with no retention,
# which fails FinOps policy checks.
# ─────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "lambda_users" {
  name              = "/aws/lambda/saas-users-handler"
  retention_in_days = 14
  tags              = merge(local.tags, { Name = "saas-users-handler-logs" })
}

resource "aws_cloudwatch_log_group" "lambda_orders" {
  name              = "/aws/lambda/saas-orders-handler"
  retention_in_days = 14
  tags              = merge(local.tags, { Name = "saas-orders-handler-logs" })
}

resource "aws_cloudwatch_log_group" "lambda_auth" {
  name              = "/aws/lambda/saas-auth-handler"
  retention_in_days = 14
  tags              = merge(local.tags, { Name = "saas-auth-handler-logs" })
}

# ─────────────────────────────────────────────────────────────
# Lambda Functions
# ─────────────────────────────────────────────────────────────
locals {
  lambda_env = {
    DB_HOST    = aws_db_instance.main.address
    DB_NAME    = "saasdb"
    DB_USER    = "saasadmin"
    SECRET_ARN = aws_secretsmanager_secret.db_password.arn
    REGION     = var.region
  }

}

resource "aws_lambda_function" "users" {
  function_name    = "saas-users-handler"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.users_handler.output_path
  source_code_hash = data.archive_file.users_handler.output_base64sha256
  memory_size      = 256
  timeout          = 30

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = local.lambda_env
  }

  tags = merge(local.tags, { Name = "saas-users-handler" })
  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy_attachment.lambda_basic,
    aws_db_instance.main,
    aws_cloudwatch_log_group.lambda_users,
    aws_cloudwatch_log_group.lambda_orders,
    aws_cloudwatch_log_group.lambda_auth,
  ]
}

resource "aws_lambda_function" "orders" {
  function_name    = "saas-orders-handler"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.orders_handler.output_path
  source_code_hash = data.archive_file.orders_handler.output_base64sha256
  memory_size      = 256
  timeout          = 30

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = local.lambda_env
  }

  tags = merge(local.tags, { Name = "saas-orders-handler" })
  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy_attachment.lambda_basic,
    aws_db_instance.main,
    aws_cloudwatch_log_group.lambda_users,
    aws_cloudwatch_log_group.lambda_orders,
    aws_cloudwatch_log_group.lambda_auth,
  ]
}

resource "aws_lambda_function" "auth" {
  function_name    = "saas-auth-handler"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.auth_handler.output_path
  source_code_hash = data.archive_file.auth_handler.output_base64sha256
  memory_size      = 256
  timeout          = 30

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = local.lambda_env
  }

  tags = merge(local.tags, { Name = "saas-auth-handler" })
  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy_attachment.lambda_basic,
    aws_db_instance.main,
    aws_cloudwatch_log_group.lambda_users,
    aws_cloudwatch_log_group.lambda_orders,
    aws_cloudwatch_log_group.lambda_auth,
  ]
}

# ─────────────────────────────────────────────────────────────
# API Gateway REST API
# ─────────────────────────────────────────────────────────────
resource "aws_api_gateway_rest_api" "main" {
  name        = "saas-api"
  description = "Multi-Tenant SaaS REST API — protected by Cognito"

  tags = merge(local.tags, { Name = "saas-api" })
}

resource "aws_api_gateway_authorizer" "cognito" {
  name            = "saas-cognito-authorizer"
  rest_api_id     = aws_api_gateway_rest_api.main.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = [aws_cognito_user_pool.main.arn]
  identity_source = "method.request.header.Authorization"
}

# ── /users resource ──────────────────────────────────────────
resource "aws_api_gateway_resource" "users" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "users"
}

resource "aws_api_gateway_method" "users_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "users_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users.id
  http_method             = aws_api_gateway_method.users_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${aws_lambda_function.users.arn}/invocations"
}

resource "aws_api_gateway_method" "users_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.users.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "users_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.users.id
  http_method             = aws_api_gateway_method.users_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${aws_lambda_function.users.arn}/invocations"
}

resource "aws_lambda_permission" "users_get" {
  statement_id  = "AllowAPIGatewayUsersGET"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.users.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

resource "aws_lambda_permission" "users_post" {
  statement_id  = "AllowAPIGatewayUsersPOST"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.users.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

# ── /orders resource ─────────────────────────────────────────
resource "aws_api_gateway_resource" "orders" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "orders"
}

resource "aws_api_gateway_method" "orders_get" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.orders.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "orders_get" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.orders.id
  http_method             = aws_api_gateway_method.orders_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${aws_lambda_function.orders.arn}/invocations"
}

resource "aws_api_gateway_method" "orders_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.orders.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "orders_post" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.orders.id
  http_method             = aws_api_gateway_method.orders_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.name}:lambda:path/2015-03-31/functions/${aws_lambda_function.orders.arn}/invocations"
}

resource "aws_lambda_permission" "orders_get" {
  statement_id  = "AllowAPIGatewayOrdersGET"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orders.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

resource "aws_lambda_permission" "orders_post" {
  statement_id  = "AllowAPIGatewayOrdersPOST"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orders.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

# ── Deployment + Stage ────────────────────────────────────────
resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  # Force a new deployment whenever any integration changes
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.users_get.id,
      aws_api_gateway_integration.users_post.id,
      aws_api_gateway_integration.orders_get.id,
      aws_api_gateway_integration.orders_post.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.users_get,
    aws_api_gateway_integration.users_post,
    aws_api_gateway_integration.orders_get,
    aws_api_gateway_integration.orders_post,
  ]
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = "prod"
  description   = "Production stage"

  tags = merge(local.tags, { Name = "saas-api-prod-stage" })
}
