# =============================================================================
# Scalable Web App with ALB & Auto Scaling
#
# Cross-variable validation rules in variables.tf need Terraform 1.9 or later.
# =============================================================================

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Project     = var.app_name
    }
  }
}

# The API token is read only from the CLOUDFLARE_API_TOKEN environment
# variable. It is never a Terraform variable and never appears in tfvars.
provider "cloudflare" {}

# =============================================================================
# LOCALS
# =============================================================================

locals {
  db_port = 5432

  # RDS identifiers and DB subnet group names must be lower case.
  db_identifier = lower("${var.app_name}-db")

  # A certificate for a single name has exactly one DNS validation record.
  acm_validation = one(aws_acm_certificate.web.domain_validation_options)
}

# =============================================================================
# DATA SOURCES
# =============================================================================

# Latest standard (not minimal) Amazon Linux 2023 x86_64 AMI on the default
# kernel, resolved at plan time from the public Systems Manager parameter that
# AWS maintains for this purpose.
data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# =============================================================================
# SUBNET — us-east-1b (Terraform-managed; destroyed with terraform destroy)
# =============================================================================

resource "aws_subnet" "web_1b" {
  vpc_id                  = var.vpc_id
  cidr_block              = "10.0.0.16/28"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.app_name}-subnet-1b"
  }
}

resource "aws_route_table_association" "web_1b" {
  subnet_id      = aws_subnet.web_1b.id
  route_table_id = var.public_route_table_id
}

locals {
  # Combine the pre-existing 1a subnets from var with the Terraform-managed 1b subnet.
  all_subnet_ids = concat(var.subnet_ids, [aws_subnet.web_1b.id])
}

# =============================================================================
# DATABASE SUBNETS — one per Availability Zone, no route out of the VPC
# =============================================================================

resource "aws_subnet" "db" {
  for_each = var.database_subnets

  vpc_id                  = var.vpc_id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.app_name}-db-subnet-${each.key}"
  }
}

# The table holds only the implicit local route for the VPC CIDR, so the
# database subnets have no path to an internet or NAT gateway. The empty list
# is deliberate: it makes Terraform remove any route added to this table by
# hand, where leaving the argument out would only ignore such routes.
resource "aws_route_table" "db" {
  vpc_id = var.vpc_id
  route  = []

  tags = {
    Name = "${var.app_name}-db-rt"
  }
}

resource "aws_route_table_association" "db" {
  for_each = aws_subnet.db

  subnet_id      = each.value.id
  route_table_id = aws_route_table.db.id
}

resource "aws_db_subnet_group" "web" {
  name        = "${local.db_identifier}-subnet-group"
  description = "Database subnets for ${var.app_name}"
  subnet_ids  = [for subnet in aws_subnet.db : subnet.id]

  tags = {
    Name = "${local.db_identifier}-subnet-group"
  }
}

# =============================================================================
# SECURITY GROUPS — one per tier: load balancer, instances, database
# =============================================================================

# --- Load balancer -----------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.app_name}-alb-sg"
  description = "Load balancer: HTTP and HTTPS from the internet"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.app_name}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet (redirected to HTTPS by the listener)"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_all_outbound" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Instances ---------------------------------------------------------------

# No port 22 and no port 443: the only way in is HTTP from the load balancer.
# Shell access is through Systems Manager Session Manager.
resource "aws_security_group" "ec2" {
  name        = "${var.app_name}-ec2-sg"
  description = "Instances: HTTP from the load balancer security group only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.app_name}-ec2-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ec2_http_from_alb" {
  security_group_id            = aws_security_group.ec2.id
  description                  = "HTTP from the load balancer security group"
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
  referenced_security_group_id = aws_security_group.alb.id
}

# Outbound stays open: the instances reach the package repositories, Secrets
# Manager and Systems Manager over HTTPS, and the database on 5432.
resource "aws_vpc_security_group_egress_rule" "ec2_all_outbound" {
  security_group_id = aws_security_group.ec2.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Database ----------------------------------------------------------------

# One ingress rule and no egress rule. Security groups are stateful, so replies
# to the instances need no egress rule.
resource "aws_security_group" "db" {
  name        = "${var.app_name}-db-sg"
  description = "Database: PostgreSQL from the instance security group only"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.app_name}-db-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_postgres_from_ec2" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the instance security group"
  ip_protocol                  = "tcp"
  from_port                    = local.db_port
  to_port                      = local.db_port
  referenced_security_group_id = aws_security_group.ec2.id
}

# =============================================================================
# IAM — instance role: Session Manager, and read access to one secret
# =============================================================================

resource "aws_iam_role" "ec2" {
  name = "${var.app_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })

  tags = {
    Name = "${var.app_name}-ec2-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Only GetSecretValue, and only on the secret that RDS manages for this
# database's master user.
resource "aws_iam_role_policy" "db_secret_read" {
  name = "${var.app_name}-db-secret-read"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadDbMasterSecret"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_db_instance.web.master_user_secret[0].secret_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.app_name}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = {
    Name = "${var.app_name}-ec2-profile"
  }
}

# =============================================================================
# CERTIFICATE AND DNS — ACM certificate validated through Cloudflare DNS
# =============================================================================

resource "aws_acm_certificate" "web" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = {
    Name = "${var.app_name}-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ACM validation CNAME, DNS only (not proxied). ACM returns the record name
# and value with a trailing dot; both are trimmed so the record is written
# without it.
resource "cloudflare_dns_record" "acm_validation" {
  zone_id = var.cloudflare_zone_id
  name    = lower(trimsuffix(local.acm_validation.resource_record_name, "."))
  type    = "CNAME"
  content = lower(trimsuffix(local.acm_validation.resource_record_value, "."))
  ttl     = 60
  proxied = false
  comment = "ACM DNS validation record, managed by Terraform"
}

# Waits until ACM has issued the certificate. The HTTPS listener takes the
# certificate ARN from this resource, so it is not created before issuance.
#
# The dependency on the validation record is explicit. The optional
# validation_record_fqdns argument is left out on purpose: it compares the
# name Cloudflare reports back with the name ACM expects, which adds a way to
# fail without adding a check, because the record is built from ACM's own
# output. What this resource waits for is issuance by ACM itself.
resource "aws_acm_certificate_validation" "web" {
  certificate_arn = aws_acm_certificate.web.arn

  depends_on = [cloudflare_dns_record.acm_validation]
}

# Hostname CNAME to the load balancer, DNS only (not proxied), so clients
# negotiate TLS with the load balancer's listener. The load balancer DNS name
# starts with the load balancer name and so can contain upper-case letters.
# DNS names are case-insensitive; it is lower-cased here to keep the record
# content in one canonical form.
resource "cloudflare_dns_record" "web" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain_name
  type    = "CNAME"
  content = lower(aws_lb.web.dns_name)
  ttl     = 60
  proxied = false
  comment = "Load balancer hostname, managed by Terraform"
}

# =============================================================================
# DATABASE — RDS for PostgreSQL, Multi-AZ DB instance deployment
#
# One DB identifier: a primary plus a synchronous standby in a second
# Availability Zone. The standby cannot be queried.
# =============================================================================

resource "aws_db_instance" "web" {
  identifier = local.db_identifier

  engine                     = "postgres"
  engine_version             = "18" # major version only; RDS picks the minor
  auto_minor_version_upgrade = true

  instance_class = var.db_instance_class
  multi_az       = true

  # Fixed size: max_allocated_storage is not set, so storage autoscaling is off.
  # No kms_key_id: storage is encrypted with the AWS-managed aws/rds key.
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  # No password argument anywhere. RDS generates the master password, stores it
  # in Secrets Manager and rotates it. Terraform is given no password; it reads
  # back the ARN of the secret.
  username                    = var.db_master_username
  manage_master_user_password = true

  port                   = local.db_port
  db_subnet_group_name   = aws_db_subnet_group.web.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period = var.db_backup_retention_period

  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.db_identifier}-final-snapshot"

  tags = {
    Name = local.db_identifier
  }
}

# =============================================================================
# LAUNCH TEMPLATE
# =============================================================================

locals {
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Boot script for Amazon Linux 2023. Runs once, as root, from cloud-init.
    #
    # Order matters. The web server is installed and started first, with the
    # database status line already on the page as "unreachable". The database
    # check runs afterwards and rewrites that line to "connected" only if it
    # succeeds. Load balancer health checks therefore never wait on, or depend
    # on, the database.
    #
    # The page shows only "connected" or "unreachable". Nothing here prints or
    # stores the database endpoint, user name, password or any other part of
    # the secret: the output of the check is discarded, and shell tracing
    # (set -x) is never turned on.

    dnf install -y httpd

    # Fetch instance metadata using IMDSv2
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/placement/availability-zone)

    # render_page STATUS
    # Writes the page with STATUS as the database status line, then moves it
    # into place so that a request never reads a half-written file.
    render_page() {
      cat > /var/www/html/index.html.new <<HTML
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <title>${var.app_name} — ${var.environment}</title>
      <style>
        body { font-family: sans-serif; text-align: center; padding: 60px;
               background: #f0f4f8; color: #333; }
        .card { display: inline-block; background: white; border-radius: 8px;
                padding: 40px 60px; box-shadow: 0 4px 16px rgba(0,0,0,.1); }
        h1 { color: #e8821a; }
        code { background: #eee; padding: 2px 6px; border-radius: 4px; }
      </style>
    </head>
    <body>
      <div class="card">
        <h1>Hello from ${var.app_name}!</h1>
        <p>Instance: <code>$INSTANCE_ID</code></p>
        <p>Availability Zone: <code>$AZ</code></p>
        <p>Environment: <strong>${var.environment}</strong></p>
        <p>Database: <strong id="db-status">$1</strong></p>
      </div>
    </body>
    </html>
    HTML
      mv -f /var/www/html/index.html.new /var/www/html/index.html
    }

    render_page "unreachable"
    systemctl enable --now httpd

    # PostgreSQL client, in its own transaction so that a problem with this
    # package cannot stop the web server above. The AWS CLI is installed only
    # if the AMI does not already provide it.
    dnf install -y postgresql18
    command -v aws >/dev/null 2>&1 || dnf install -y awscli-2

    # db_check
    # Succeeds only if "SELECT 1" runs over a TLS connection (sslmode=require).
    # The secret is fetched with the instance role and piped straight into a
    # short Python step that reads the user name and password and replaces
    # itself with psql, handing both over through that one process's
    # environment. The password is never held in a shell variable, never put on
    # a command line and never written to a file. All output is discarded.
    db_check() {
      aws secretsmanager get-secret-value \
        --region "${var.region}" \
        --secret-id "${aws_db_instance.web.master_user_secret[0].secret_arn}" \
        --query SecretString \
        --output text \
        --cli-connect-timeout 5 \
        --cli-read-timeout 10 2>/dev/null |
        PGHOST="${aws_db_instance.web.address}" \
        PGPORT="${aws_db_instance.web.port}" \
        PGDATABASE="postgres" \
        PGSSLMODE="require" \
        PGCONNECT_TIMEOUT="5" \
        python3 -c 'import json, os, sys; s = json.load(sys.stdin); os.execvpe("psql", ["psql", "--no-psqlrc", "--no-password", "--quiet", "--tuples-only", "--command", "SELECT 1"], dict(os.environ, PGUSER=s["username"], PGPASSWORD=s["password"]))' \
        >/dev/null 2>&1
    }

    # Short bounded retry: at most five attempts, ten seconds apart.
    DB_STATUS="unreachable"
    for attempt in 1 2 3 4 5; do
      if db_check; then
        DB_STATUS="connected"
        break
      fi
      [ "$attempt" -lt 5 ] && sleep 10
    done

    render_page "$DB_STATUS"
  EOF
  )
}

resource "aws_launch_template" "web" {
  name                   = "${var.app_name}Template"
  image_id               = data.aws_ssm_parameter.al2023_ami.insecure_value
  instance_type          = var.instance_type
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null
  vpc_security_group_ids = [aws_security_group.ec2.id]
  user_data              = local.user_data

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  # IMDSv2 only. A hop limit of 1 keeps the metadata service, and with it the
  # role credentials that can read the database secret, on the instance itself.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.app_name}-instance"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.app_name}-volume"
    }
  }

  tags = {
    Name = "${var.app_name}Template"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# ALB — TARGET GROUP
# =============================================================================

resource "aws_lb_target_group" "web" {
  name        = "${var.app_name}-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    port                = "traffic-port"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = {
    Name = "${var.app_name}-tg"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# =============================================================================
# ALB — LOAD BALANCER & LISTENERS
# =============================================================================

resource "aws_lb" "web" {
  name               = "${var.app_name}ALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.all_subnet_ids

  enable_deletion_protection = false

  tags = {
    Name = "${var.app_name}ALB"
  }
}

# TLS ends here. The load balancer forwards to the instances over HTTP on
# port 80 inside the VPC.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = aws_acm_certificate_validation.web.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }

  tags = {
    Name = "${var.app_name}-listener-https"
  }
}

# Port 80 carries no application traffic: every request is answered with a
# permanent redirect to HTTPS on 443.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = {
    Name = "${var.app_name}-listener-http"
  }
}

# =============================================================================
# AUTO SCALING GROUP
# =============================================================================

resource "aws_autoscaling_group" "web" {
  name                      = "${var.app_name}ASG"
  desired_capacity          = var.asg_desired
  min_size                  = var.asg_min
  max_size                  = var.asg_max
  vpc_zone_identifier       = local.all_subnet_ids
  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  # Propagate the provider default_tags block onto ASG-launched instances
  # by using tag blocks here (ASG uses its own tag schema).
  tag {
    key                 = "Name"
    value               = "${var.app_name}-asg-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Environment"
    value               = var.environment
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "terraform"
    propagate_at_launch = true
  }

  # Instances run their database check once, at boot. They must not launch
  # until the database exists, the role can read its secret, and the target
  # group is attached to a listener.
  depends_on = [
    aws_db_instance.web,
    aws_iam_role_policy.db_secret_read,
    aws_iam_role_policy_attachment.ssm,
    aws_lb_listener.https,
  ]

  lifecycle {
    create_before_destroy = true
    # Prevent Terraform from resetting desired capacity after manual scaling
    ignore_changes = [desired_capacity]
  }
}

# =============================================================================
# AUTO SCALING POLICIES — Step Scaling driven by CloudWatch CPU alarms
#
# Two independent step-scaling policies are used so each direction has its own
# cooldown and step adjustments, giving finer control than target-tracking alone.
# =============================================================================

resource "aws_autoscaling_policy" "scale_out" {
  name                    = "${var.app_name}-scale-out"
  autoscaling_group_name  = aws_autoscaling_group.web.name
  adjustment_type         = "ChangeInCapacity"
  policy_type             = "StepScaling"
  metric_aggregation_type = "Average"

  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0 # CPU between threshold and threshold+20
    metric_interval_upper_bound = 20
  }

  step_adjustment {
    scaling_adjustment          = 2
    metric_interval_lower_bound = 20 # CPU more than threshold+20 (sustained spike)
  }
}

resource "aws_autoscaling_policy" "scale_in" {
  name                    = "${var.app_name}-scale-in"
  autoscaling_group_name  = aws_autoscaling_group.web.name
  adjustment_type         = "ChangeInCapacity"
  policy_type             = "StepScaling"
  metric_aggregation_type = "Average"

  step_adjustment {
    scaling_adjustment          = -1
    metric_interval_upper_bound = 0 # CPU below threshold
  }
}

# =============================================================================
# CLOUDWATCH METRIC ALARMS
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.app_name}-cpu-high"
  alarm_description   = "Scale out when average CPU > ${var.scale_out_cpu_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = var.scale_out_cpu_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_out.arn]

  tags = {
    Name = "${var.app_name}-cpu-high"
  }
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.app_name}-cpu-low"
  alarm_description   = "Scale in when average CPU < ${var.scale_in_cpu_threshold}%"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = var.scale_in_cpu_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_in.arn]

  tags = {
    Name = "${var.app_name}-cpu-low"
  }
}
