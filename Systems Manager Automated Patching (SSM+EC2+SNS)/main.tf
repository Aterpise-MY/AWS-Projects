###############################################################################
# DATA SOURCES
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Latest AMIs via SSM public parameters (no hard-coded, region-specific IDs).
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_ssm_parameter" "ubuntu2204" {
  name = "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id"
}

###############################################################################
# LOCALS — instance expansion
###############################################################################

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Deterministic, sorted list of patch-group keys (keys() returns sorted).
  group_keys = keys(var.patch_groups)

  ami_by_os = {
    "amazon-linux-2023" = data.aws_ssm_parameter.al2023.value
    "ubuntu-22.04"      = data.aws_ssm_parameter.ubuntu2204.value
  }

  # Distribute `instance_count` total instances round-robin across the patch
  # groups. instance_count=2 -> {instance-0 => al2023, instance-1 => ubuntu}.
  instance_defs = {
    for i in range(var.instance_count) :
    "instance-${i}" => {
      ordinal       = i
      group_key     = local.group_keys[i % length(local.group_keys)]
      patch_group   = var.patch_groups[local.group_keys[i % length(local.group_keys)]].patch_group
      os_family     = var.patch_groups[local.group_keys[i % length(local.group_keys)]].os_family
      instance_type = var.patch_groups[local.group_keys[i % length(local.group_keys)]].instance_type
    }
  }
}

###############################################################################
# NETWORKING — self-contained minimal VPC
#
# Public subnet + IGW + default route. Instances get a public IP so the SSM
# Agent reaches the public SSM endpoints over the IGW — no interface VPC
# endpoints (ssm/ssmmessages/ec2messages) required for this demo.
###############################################################################

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-subnet"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

###############################################################################
# IAM — EC2 INSTANCE ROLE & PROFILE (SSM-managed)
###############################################################################

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm_instance" {
  name               = "${local.name_prefix}-ssm-instance-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Name = "${local.name_prefix}-ssm-instance-role"
  }
}

# Core managed policy: registers the instance with SSM (Fleet Manager, Run
# Command, Patch Manager, Session Manager). This is all a patch target needs.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_instance" {
  name = "${local.name_prefix}-ssm-instance-profile"
  role = aws_iam_role.ssm_instance.name

  tags = {
    Name = "${local.name_prefix}-ssm-instance-profile"
  }
}

###############################################################################
# IAM — MAINTENANCE WINDOW SERVICE ROLE
#
# Assumed by SSM to run the AWS-RunPatchBaseline task and publish task
# lifecycle notifications to the patch-alerts SNS topic.
###############################################################################

data "aws_iam_policy_document" "mw_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "maintenance_window" {
  name               = "${local.name_prefix}-mw-role"
  assume_role_policy = data.aws_iam_policy_document.mw_assume.json

  tags = {
    Name = "${local.name_prefix}-mw-role"
  }
}

# AWS-managed policy that grants SSM permission to run Maintenance Window tasks
# (includes ssm:SendCommand and sns:Publish for notification config).
resource "aws_iam_role_policy_attachment" "mw_managed" {
  role       = aws_iam_role.maintenance_window.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonSSMMaintenanceWindowRole"
}

###############################################################################
# SECURITY GROUP — egress only
#
# SSM is pull-based over outbound HTTPS (443), so NO inbound rule is needed.
###############################################################################

resource "aws_security_group" "ssm_egress" {
  name_prefix = "${local.name_prefix}-ssm-egress-"
  description = "Egress-only SG for SSM-managed patch demo instances (no inbound)"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allow all outbound (SSM endpoints, package repos)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-ssm-egress-sg"
  }
}

###############################################################################
# EC2 — DEMO PATCH TARGETS
#
# Each instance carries the reserved `Patch Group` tag (note the space in the
# key). Patch Manager uses this tag to associate the instance with a baseline
# and the maintenance window targets it by the same tag.
###############################################################################

resource "aws_instance" "demo" {
  for_each = local.instance_defs

  ami                    = local.ami_by_os[each.value.os_family]
  instance_type          = each.value.instance_type
  subnet_id              = aws_subnet.public.id
  iam_instance_profile   = aws_iam_instance_profile.ssm_instance.name
  vpc_security_group_ids = [aws_security_group.ssm_egress.id]

  # Required so the SSM Agent can reach the public SSM endpoints in the
  # default VPC without interface endpoints.
  associate_public_ip_address = true

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  tags = {
    Name          = "${local.name_prefix}-${each.key}-${each.value.group_key}"
    "Patch Group" = each.value.patch_group
    Environment   = var.environment
    Application   = var.application
  }
}

###############################################################################
# PATCH BASELINES
###############################################################################

# --- Amazon Linux 2023 ------------------------------------------------------
# Approve Security-classified Critical/Important patches after 7 days.
resource "aws_ssm_patch_baseline" "al2023" {
  name             = "${local.name_prefix}-al2023-baseline"
  description      = "AL2023 — Security Critical/Important, ${var.approve_after_days}d auto-approve, HIGH compliance"
  operating_system = "AMAZON_LINUX_2023"

  approved_patches_compliance_level = "HIGH"

  approval_rule {
    approve_after_days = var.approve_after_days
    compliance_level   = "HIGH"

    patch_filter {
      key    = "CLASSIFICATION"
      values = ["Security"]
    }

    patch_filter {
      key    = "SEVERITY"
      values = ["Critical", "Important"]
    }
  }

  # Exception example: never auto-install the ansible package (change-controlled
  # separately). BLOCK also prevents it being pulled in as a dependency.
  rejected_patches        = ["ansible"]
  rejected_patches_action = "BLOCK"

  tags = {
    Name        = "${local.name_prefix}-al2023-baseline"
    PatchGroup  = var.patch_groups["al2023"].patch_group
    OSFamily    = "amazon-linux-2023"
  }
}

# --- Ubuntu 22.04 -----------------------------------------------------------
# NOTE: Ubuntu baselines filter on PRODUCT / PRIORITY / SECTION — the OS does
# NOT expose a CLASSIFICATION key, so the requested "Security + Bugfix" intent
# is expressed via Ubuntu's PRIORITY levels (Required/Important/Standard) plus
# the security-relevant SECTIONs. This is the correct API surface for UBUNTU.
resource "aws_ssm_patch_baseline" "ubuntu" {
  name             = "${local.name_prefix}-ubuntu-baseline"
  description      = "Ubuntu 22.04 — required/important priorities, ${var.approve_after_days}d auto-approve"
  operating_system = "UBUNTU"

  approved_patches_compliance_level = "HIGH"

  approval_rule {
    approve_after_days = var.approve_after_days
    compliance_level   = "HIGH"

    patch_filter {
      key    = "PRODUCT"
      values = ["Ubuntu22.04"]
    }

    patch_filter {
      key    = "PRIORITY"
      values = ["Required", "Important", "Standard"]
    }

    patch_filter {
      key    = "SECTION"
      values = ["*"]
    }
  }

  # Exception example: pre-approve the openssl package regardless of the rule
  # delay, so a fresh OpenSSL CVE fix can go in on the next window immediately.
  approved_patches = ["openssl"]

  tags = {
    Name       = "${local.name_prefix}-ubuntu-baseline"
    PatchGroup = var.patch_groups["ubuntu"].patch_group
    OSFamily   = "ubuntu-22.04"
  }
}

###############################################################################
# PATCH GROUPS — bind each baseline to its tag value
###############################################################################

resource "aws_ssm_patch_group" "al2023" {
  baseline_id = aws_ssm_patch_baseline.al2023.id
  patch_group = var.patch_groups["al2023"].patch_group
}

resource "aws_ssm_patch_group" "ubuntu" {
  baseline_id = aws_ssm_patch_baseline.ubuntu.id
  patch_group = var.patch_groups["ubuntu"].patch_group
}

###############################################################################
# MAINTENANCE WINDOWS — staggered (AL2023 02:00 UTC, Ubuntu 03:00 UTC)
###############################################################################

resource "aws_ssm_maintenance_window" "al2023" {
  name                       = "${local.name_prefix}-al2023-mw"
  description                = "Weekly patch window for ${var.patch_groups["al2023"].patch_group}"
  schedule                   = var.al2023_schedule
  schedule_timezone          = "UTC"
  duration                   = var.window_duration_hours
  cutoff                     = var.window_cutoff_hours
  allow_unassociated_targets = false

  tags = {
    Name       = "${local.name_prefix}-al2023-mw"
    PatchGroup = var.patch_groups["al2023"].patch_group
  }
}

resource "aws_ssm_maintenance_window" "ubuntu" {
  name                       = "${local.name_prefix}-ubuntu-mw"
  description                = "Weekly patch window for ${var.patch_groups["ubuntu"].patch_group}"
  schedule                   = var.ubuntu_schedule
  schedule_timezone          = "UTC"
  duration                   = var.window_duration_hours
  cutoff                     = var.window_cutoff_hours
  allow_unassociated_targets = false

  tags = {
    Name       = "${local.name_prefix}-ubuntu-mw"
    PatchGroup = var.patch_groups["ubuntu"].patch_group
  }
}

###############################################################################
# MAINTENANCE WINDOW TARGETS — register instances by Patch Group tag
###############################################################################

resource "aws_ssm_maintenance_window_target" "al2023" {
  window_id     = aws_ssm_maintenance_window.al2023.id
  name          = "${local.name_prefix}-al2023-target"
  description   = "Targets instances tagged Patch Group=${var.patch_groups["al2023"].patch_group}"
  resource_type = "INSTANCE"

  targets {
    key    = "tag:Patch Group"
    values = [var.patch_groups["al2023"].patch_group]
  }
}

resource "aws_ssm_maintenance_window_target" "ubuntu" {
  window_id     = aws_ssm_maintenance_window.ubuntu.id
  name          = "${local.name_prefix}-ubuntu-target"
  description   = "Targets instances tagged Patch Group=${var.patch_groups["ubuntu"].patch_group}"
  resource_type = "INSTANCE"

  targets {
    key    = "tag:Patch Group"
    values = [var.patch_groups["ubuntu"].patch_group]
  }
}

###############################################################################
# MAINTENANCE WINDOW TASKS — AWS-RunPatchBaseline (Operation = Install)
###############################################################################

resource "aws_ssm_maintenance_window_task" "al2023" {
  window_id        = aws_ssm_maintenance_window.al2023.id
  name             = "${local.name_prefix}-al2023-patch-task"
  description      = "Install approved patches on ${var.patch_groups["al2023"].patch_group}"
  task_type        = "RUN_COMMAND"
  task_arn         = "AWS-RunPatchBaseline"
  priority         = 1
  service_role_arn = aws_iam_role.maintenance_window.arn
  max_concurrency  = var.max_concurrency
  max_errors       = var.max_errors

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.al2023.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      timeout_seconds  = 3600
      service_role_arn = aws_iam_role.maintenance_window.arn

      parameter {
        name   = "Operation"
        values = ["Install"]
      }

      notification_config {
        notification_arn    = aws_sns_topic.patch_alerts.arn
        notification_events = ["Failed", "TimedOut"]
        notification_type   = "Command"
      }
    }
  }
}

resource "aws_ssm_maintenance_window_task" "ubuntu" {
  window_id        = aws_ssm_maintenance_window.ubuntu.id
  name             = "${local.name_prefix}-ubuntu-patch-task"
  description      = "Install approved patches on ${var.patch_groups["ubuntu"].patch_group}"
  task_type        = "RUN_COMMAND"
  task_arn         = "AWS-RunPatchBaseline"
  priority         = 1
  service_role_arn = aws_iam_role.maintenance_window.arn
  max_concurrency  = var.max_concurrency
  max_errors       = var.max_errors

  targets {
    key    = "WindowTargetIds"
    values = [aws_ssm_maintenance_window_target.ubuntu.id]
  }

  task_invocation_parameters {
    run_command_parameters {
      timeout_seconds  = 3600
      service_role_arn = aws_iam_role.maintenance_window.arn

      parameter {
        name   = "Operation"
        values = ["Install"]
      }

      notification_config {
        notification_arn    = aws_sns_topic.patch_alerts.arn
        notification_events = ["Failed", "TimedOut"]
        notification_type   = "Command"
      }
    }
  }
}

###############################################################################
# SNS — patch-alerts topic (+ optional email subscription)
###############################################################################

resource "aws_sns_topic" "patch_alerts" {
  name = "${local.name_prefix}-patch-alerts"

  tags = {
    Name = "${local.name_prefix}-patch-alerts"
  }
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.patch_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
