terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

locals {
  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
  }
}

# ECR Repository
resource "aws_ecr_repository" "app_runner_repo" {
  name                 = var.ecr_repository_name
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.enable_image_scanning
  }

  tags = {
    Name = "${var.project_name}-ecr-repo"
  }
}

# ECR Lifecycle Policy - Keep only recent images
resource "aws_ecr_lifecycle_policy" "app_runner_lifecycle" {
  repository = aws_ecr_repository.app_runner_repo.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images, expire older ones"
        selection = {
          tagStatus     = "any"
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# IAM Role for App Runner
resource "aws_iam_role" "app_runner_service_role" {
  name = "${var.project_name}-app-runner-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "build.apprunner.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-app-runner-service-role"
  }
}

# IAM Policy for ECR access — use AWS managed policy (GetAuthorizationToken requires Resource: *)
resource "aws_iam_role_policy_attachment" "app_runner_ecr_policy" {
  role       = aws_iam_role.app_runner_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess"
}

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "app_runner_logs" {
  name              = "/aws/apprunner/${var.project_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project_name}-logs"
  }
}

# App Runner Service
resource "aws_apprunner_service" "main" {
  service_name = var.service_name

  source_configuration {
    authentication_configuration {
      access_role_arn = aws_iam_role.app_runner_service_role.arn
    }

    image_repository {
      image_identifier      = "${aws_ecr_repository.app_runner_repo.repository_url}:${var.image_tag}"
      image_repository_type = "ECR"
      image_configuration {
        port = tostring(var.container_port)

        runtime_environment_variables = var.environment_variables

        runtime_environment_secrets = var.environment_secrets
      }
    }
  }

  instance_configuration {
    instance_role_arn = aws_iam_role.app_runner_instance_role.arn
    cpu               = var.cpu
    memory            = var.memory
  }

  auto_scaling_configuration_arn = aws_apprunner_auto_scaling_configuration_version.main.arn

  network_configuration {
    ingress_configuration {
      is_publicly_accessible = var.is_publicly_accessible
    }

    egress_configuration {
      egress_type       = var.egress_type
      vpc_connector_arn = var.vpc_connector_arn
    }
  }

  tags = {
    Name = var.service_name
  }

  depends_on = [aws_iam_role_policy_attachment.app_runner_ecr_policy]
}

# IAM Role for App Runner Instance
resource "aws_iam_role" "app_runner_instance_role" {
  name = "${var.project_name}-app-runner-instance-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "tasks.apprunner.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-app-runner-instance-role"
  }
}

# IAM Policy for instance to write logs
resource "aws_iam_role_policy" "app_runner_instance_logs_policy" {
  name = "${var.project_name}-app-runner-instance-logs-policy"
  role = aws_iam_role.app_runner_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.app_runner_logs.arn}:*"
      }
    ]
  })
}

# Auto Scaling Configuration
resource "aws_apprunner_auto_scaling_configuration_version" "main" {
  auto_scaling_configuration_name = "${var.project_name}-auto-scaling"
  max_concurrency                 = var.max_concurrency
  min_size                        = var.min_instances
  max_size                        = var.max_instances

  tags = {
    Name = "${var.project_name}-auto-scaling"
  }
}

# CloudWatch Alarm - CPU Utilization
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/AppRunner"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  alarm_description   = "Alert when CPU exceeds ${var.cpu_alarm_threshold}%"
  dimensions = {
    ServiceArn = aws_apprunner_service.main.arn
  }

  tags = {
    Name = "${var.project_name}-cpu-alarm"
  }
}

# CloudWatch Alarm - Memory Utilization
resource "aws_cloudwatch_metric_alarm" "memory_high" {
  alarm_name          = "${var.project_name}-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/AppRunner"
  period              = 300
  statistic           = "Average"
  threshold           = var.memory_alarm_threshold
  alarm_description   = "Alert when memory exceeds ${var.memory_alarm_threshold}%"
  dimensions = {
    ServiceArn = aws_apprunner_service.main.arn
  }

  tags = {
    Name = "${var.project_name}-memory-alarm"
  }
}

# CloudWatch Alarm - Deployment Status
resource "aws_cloudwatch_metric_alarm" "deployment_failed" {
  alarm_name          = "${var.project_name}-deployment-failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "DeploymentFailures"
  namespace           = "AWS/AppRunner"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "Alert when deployment fails"
  dimensions = {
    ServiceArn = aws_apprunner_service.main.arn
  }

  tags = {
    Name = "${var.project_name}-deployment-alarm"
  }
}
