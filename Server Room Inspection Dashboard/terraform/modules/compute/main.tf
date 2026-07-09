# ===========================================================================
# compute module — Phase 3 dashboard serving layer (ECS Fargate + ALB).
# ---------------------------------------------------------------------------
# Implements PHASE3_DASHBOARD_DESIGN.md section 3.1: an internet-facing ALB in
# the public subnets forwards to a Fargate service in the private-app subnets,
# which reads its DB credentials from Secrets Manager (task role) and connects
# to the private RDS as the srid_app least-privilege login. Container image is
# pulled from a CMK-encrypted ECR repo; stdout/stderr ships to a CMK-encrypted
# CloudWatch log group.
#
# Demo posture: the listener is plain HTTP:80 (see PHASE3 section 5). Switch to
# HTTPS:443 by setting alb_listener_port = 443 and adding an ACM cert + a
# certificate_arn on the listener (requires a domain — real artifact needed).
# ===========================================================================

# ------------------------------ ECR repository -----------------------------
resource "aws_ecr_repository" "this" {
  name                 = "${var.name_prefix}-dashboard"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  tags = { Name = "${var.name_prefix}-dashboard" }
}

# Expire untagged images 7 days after push to control storage cost.
resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ------------------------------- ECS cluster -------------------------------
# Container Insights left OFF (default) to avoid the per-metric ingest cost on
# a single low-traffic task. Enable via a `setting` block if deeper ECS
# observability is needed later.
resource "aws_ecs_cluster" "this" {
  name = var.name_prefix

  tags = { Name = var.name_prefix }
}

# ---------------------------- CloudWatch logs ------------------------------
# CMK-encrypted. The CMK's AllowCloudWatchLogsToUseKey statement (modules/kms)
# already grants logs.<region>.amazonaws.com — no key-policy change needed.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}-dashboard"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = { Name = "${var.name_prefix}-dashboard-logs" }
}

# ---------------------------- Task definition ------------------------------
resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-dashboard"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  execution_role_arn       = var.ecs_task_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # The app fetches DB_SECRET_ARN itself at startup via the TASK role (SDK
  # call). Deliberately NO `secrets` block here — that would move the
  # GetSecretValue/kms:Decrypt requirement onto the execution role.
  container_definitions = jsonencode([
    {
      name      = "dashboard"
      image     = "${aws_ecr_repository.this.repository_url}:${var.image_tag}"
      essential = true

      portMappings = [
        {
          containerPort = var.app_port
          hostPort      = var.app_port
          protocol      = "tcp"
        }
      ]

      environment = [
        { name = "DB_SECRET_ARN", value = var.db_secret_arn },
        { name = "AWS_REGION", value = var.region },
        { name = "APP_PORT", value = tostring(var.app_port) }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "dashboard"
        }
      }
    }
  ])

  tags = { Name = "${var.name_prefix}-dashboard" }
}

# ------------------------- Application Load Balancer ------------------------
resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_lb_target_group" "this" {
  name                 = "${var.name_prefix}-tg"
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = var.app_port
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = var.health_check_matcher
    protocol            = "HTTP"
    interval            = var.health_check_interval
    healthy_threshold   = var.healthy_threshold
    unhealthy_threshold = var.unhealthy_threshold
  }

  tags = { Name = "${var.name_prefix}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.alb_listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  tags = { Name = "${var.name_prefix}-http-listener" }
}

# ------------------------------- ECS service -------------------------------
resource "aws_ecs_service" "this" {
  name            = "${var.name_prefix}-dashboard"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.app_subnet_ids
    security_groups  = [var.app_sg_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.this.arn
    container_name   = "dashboard"
    container_port   = var.app_port
  }

  health_check_grace_period_seconds = 60

  depends_on = [aws_lb_listener.http]

  # Out-of-band image deploys (new task-definition revision pushed by CI) and
  # any manual scale must not show as drift on the next plan.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }

  tags = { Name = "${var.name_prefix}-dashboard" }
}

# ===========================================================================
# IAM policy adds (inline) onto the existing Phase 0 role stubs.
# ===========================================================================

# --- Execution role: ECR pull + log write + CMK decrypt --------------------
data "aws_iam_policy_document" "execution_extra" {
  statement {
    sid       = "EcrAuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]
    resources = [aws_ecr_repository.this.arn]
  }

  statement {
    sid       = "WriteLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  # Needed to pull from the KMS-encrypted ECR repo and stream to the
  # KMS-encrypted log group.
  statement {
    sid       = "DecryptForPullAndLogs"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "execution_extra" {
  name   = "${var.name_prefix}-ecs-exec-extra"
  role   = var.ecs_task_execution_role_name
  policy = data.aws_iam_policy_document.execution_extra.json
}

# --- Task role: read the DB secret at runtime ------------------------------
data "aws_iam_policy_document" "task_extra" {
  statement {
    sid       = "ReadDbSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_secret_arn]
  }

  statement {
    sid       = "DecryptSecret"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "task_extra" {
  name   = "${var.name_prefix}-ecs-task-extra"
  role   = var.ecs_task_role_name
  policy = data.aws_iam_policy_document.task_extra.json
}
