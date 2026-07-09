# ---------------------------------------------------------------------------
# IAM module — foundational execution-role stubs (least privilege).
#
# Later phases attach resource-scoped inline policies to these roles:
#   - ecs_task_execution_role : pulls images / writes logs (managed policy now)
#   - ecs_task_role           : the app's runtime identity (no policies yet)
#   - lambda_execution_role   : Lambda runtime (basic logging managed policy)
#
# No wildcard-admin policies. No long-lived access keys are created anywhere.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ----------------------- ECS task execution role ---------------------------
resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.name_prefix}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Name = "${var.name_prefix}-ecs-task-execution"
  }
}

# AWS-managed policy: ECR pull + CloudWatch Logs write for the ECS agent.
resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --------------------------- ECS task role ---------------------------------
# The runtime identity for the container. Intentionally has NO policies yet;
# later phases attach scoped permissions (Secrets Manager read, S3, SES...).
resource "aws_iam_role" "ecs_task" {
  name               = "${var.name_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json

  tags = {
    Name = "${var.name_prefix}-ecs-task"
  }
}

# ----------------------- Lambda execution role -----------------------------
resource "aws_iam_role" "lambda_execution" {
  name               = "${var.name_prefix}-lambda-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Name = "${var.name_prefix}-lambda-exec"
  }
}

# AWS-managed policy: CloudWatch Logs group/stream/put for Lambda.
resource "aws_iam_role_policy_attachment" "lambda_basic_logging" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
