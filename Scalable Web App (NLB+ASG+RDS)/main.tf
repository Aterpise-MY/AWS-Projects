###############################################################################
# DATA SOURCES
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Amazon Linux 2023 x86_64 AMI (standard AMI, default kernel), published
# by AWS as a public SSM parameter. Not read when var.ami_id overrides it.
data "aws_ssm_parameter" "al2023_ami" {
  count = var.ami_id == "" ? 1 : 0

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

###############################################################################
# NETWORKING — VPC MODULE
###############################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-${var.environment}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  # Database tier: dedicated subnets, the module's DB subnet group, and separate
  # database route tables that hold the local VPC route only. The two route
  # flags are the module defaults; they are set here so the "no NAT gateway
  # route, no internet gateway route" intent is explicit. Without
  # create_database_subnet_route_table the module would attach these subnets to
  # the private (NAT-routed) route tables.
  database_subnets                       = var.database_subnet_cidrs
  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_nat_gateway_route      = false
  create_database_internet_gateway_route = false

  enable_nat_gateway     = true
  single_nat_gateway     = false # one NAT GW per AZ for HA
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

###############################################################################
# SECURITY GROUPS
###############################################################################

# NLB security group — accepts public traffic on 443 only.
# Security Note: port 443 is open to 0.0.0.0/0; this is intentional because
# the NLB must be reachable from the internet. Port 80 is closed: there is no
# listener and no rule for it, because an NLB can only forward, not redirect.
resource "aws_security_group" "nlb" {
  name        = "${var.project_name}-${var.environment}-nlb-sg"
  description = "Allow inbound TLS 443 to the NLB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-nlb-sg"
  }
}

# EC2 security group — only the NLB can reach instances on port 80.
resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-${var.environment}-ec2-sg"
  description = "Allow HTTP from NLB only; allow all outbound for package installs"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTP from NLB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.nlb.id]
  }

  egress {
    description = "Allow all outbound (package installs, SSM, etc.)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-sg"
  }
}

# DB security group — PostgreSQL from the EC2 security group only, by
# security-group reference. There is no other ingress and no egress rule: the
# database opens no outbound connections, and replies to the instances are
# allowed because security groups are stateful.
resource "aws_security_group" "db" {
  name        = "${var.project_name}-${var.environment}-db-sg"
  description = "Allow PostgreSQL from the EC2 security group only"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from EC2 instances"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  # Explicitly empty, so the plan shows that this group has no egress rules.
  egress = []

  tags = {
    Name = "${var.project_name}-${var.environment}-db-sg"
  }
}

###############################################################################
# DATABASE — RDS FOR POSTGRESQL (MULTI-AZ DB INSTANCE)
#
# One DB identifier: a primary plus a synchronous standby in a second AZ, with
# a single endpoint. The standby cannot be queried.
#
# There is no password argument and no password variable. RDS generates the
# master password, stores it in Secrets Manager and rotates it; this
# configuration only ever handles the secret's ARN.
#
# Only the major engine version is set, with automatic minor upgrades on, so
# RDS picks the minor version.
###############################################################################

resource "aws_db_instance" "main" {
  identifier = "${var.project_name}-${var.environment}-db"

  engine                     = "postgres"
  engine_version             = "18"
  auto_minor_version_upgrade = true
  instance_class             = var.db_instance_class
  multi_az                   = true

  # 20 GB gp3, encrypted with the AWS-managed aws/rds key (no kms_key_id).
  # max_allocated_storage is not set, so storage autoscaling stays off.
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  username                    = var.db_master_username
  manage_master_user_password = true

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period = var.db_backup_retention_period

  # Production note: a production stack would turn deletion protection on and
  # keep a final snapshot. The defaults suit a stack that is routinely
  # destroyed and holds no real data.
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${var.project_name}-${var.environment}-db-final"

  tags = {
    Name = "${var.project_name}-${var.environment}-db"
  }
}

###############################################################################
# IAM — EC2 ROLE & INSTANCE PROFILE
###############################################################################

resource "aws_iam_role" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-ec2-role"
  }
}

# Grants SSM Session Manager access so instances are reachable without a bastion.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets instances read the one RDS-managed master secret, for the boot-time
# database check in user data. One action on one secret ARN, nothing else.
resource "aws_iam_role_policy" "db_secret_read" {
  name = "${var.project_name}-${var.environment}-db-secret-read"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadDbMasterSecret"
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_db_instance.main.master_user_secret[0].secret_arn
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-${var.environment}-ec2-profile"
  role = aws_iam_role.ec2.name
}

###############################################################################
# LAUNCH TEMPLATE
###############################################################################

locals {
  # Latest Amazon Linux 2023 x86_64 AMI unless var.ami_id overrides it.
  ami_id = var.ami_id != "" ? var.ami_id : one(data.aws_ssm_parameter.al2023_ami[*].insecure_value)

  # Per-web-server settings on Amazon Linux 2023. One user data script serves
  # both web_server variants, so the database check exists in one place.
  web_servers = {
    nginx = {
      package  = "nginx"
      service  = "nginx"
      doc_root = "/usr/share/nginx/html"
      label    = "Nginx"
    }
    apache = {
      package  = "httpd"
      service  = "httpd"
      doc_root = "/var/www/html"
      label    = "Apache"
    }
  }
  web = local.web_servers[var.web_server]

  # User data for Amazon Linux 2023 only (dnf and AL2023 package names).
  #
  # Boot-time database check: the instance role reads the RDS-managed master
  # secret, psql runs SELECT 1 with TLS required, and the page gets one line,
  # "Database: connected" or "Database: unreachable".
  #   - The web server is installed and started first and the page is written
  #     whatever the check returns, so NLB health checks never depend on the
  #     database.
  #   - The script writes nothing but that one word to the page, and nothing to
  #     a log or to disk: the check's output is captured or discarded, and
  #     there is no "set -x". The user name and password are read from the
  #     secret at run time and reach psql only through its process environment.
  #   - The retry is bounded: 5 attempts, 5 seconds apart.
  #
  # Note: the database address, port and secret ARN are part of this user data
  # text, so they are readable wherever user data is (the launch template, and
  # the copy cloud-init keeps on the instance). None of them is a credential.
  # The user name and password are never in user data.
  # Note: the check uses the master credential. That is acceptable for a
  # connectivity proof and not for a real application.
  # Note: the status is a boot-time snapshot. It does not change if the
  # database becomes unreachable later.
  # Note: sslmode=require encrypts the connection but does not verify the
  # server certificate.
  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf update -y
    dnf install -y ${local.web.package}
    systemctl enable ${local.web.service}
    systemctl start ${local.web.service}

    # PostgreSQL client for the boot-time database check, newest first: an AMI
    # pinned to an older AL2023 release does not carry postgresql18. A failed
    # install is not fatal; the check then reports "unreachable".
    for pkg in postgresql18 postgresql17 postgresql16 postgresql15; do
      if dnf install -y "$pkg"; then
        break
      fi
    done

    # Fetch instance metadata (IMDSv2)
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/placement/availability-zone)

    # Boot-time database check. The output of every command in db_check is
    # captured or discarded, so nothing from the secret or the connection
    # reaches the cloud-init log.
    db_check() {
      local secret db_user db_pass
      secret=$(timeout 10 aws secretsmanager get-secret-value \
        --region "${var.region}" \
        --secret-id "${aws_db_instance.main.master_user_secret[0].secret_arn}" \
        --query SecretString --output text 2>/dev/null) || return 1
      db_user=$(printf '%s' "$secret" | python3 -c \
        'import json,sys; sys.stdout.write(json.load(sys.stdin)["username"])' 2>/dev/null) || return 1
      db_pass=$(printf '%s' "$secret" | python3 -c \
        'import json,sys; sys.stdout.write(json.load(sys.stdin)["password"])' 2>/dev/null) || return 1
      PGHOST="${aws_db_instance.main.address}" PGPORT="${aws_db_instance.main.port}" \
        PGDATABASE=postgres PGUSER="$db_user" PGPASSWORD="$db_pass" \
        PGSSLMODE=require PGCONNECT_TIMEOUT=5 \
        psql -X -q -w -tAc 'SELECT 1' >/dev/null 2>&1
    }

    DB_STATUS="unreachable"
    for attempt in 1 2 3 4 5; do
      if db_check; then
        DB_STATUS="connected"
        break
      fi
      if [ "$attempt" -lt 5 ]; then
        sleep 5
      fi
    done

    cat > ${local.web.doc_root}/index.html <<HTML
    <!DOCTYPE html>
    <html>
      <head><title>${var.project_name}</title></head>
      <body>
        <h1>${var.project_name} — ${var.environment}</h1>
        <p>Instance ID: $INSTANCE_ID</p>
        <p>Availability Zone: $AZ</p>
        <p>Web Server: ${local.web.label}</p>
        <p>Database: $DB_STATUS</p>
      </body>
    </html>
    HTML
    systemctl restart ${local.web.service}
  EOF
}

resource "aws_launch_template" "web" {
  name_prefix   = "${var.project_name}-${var.environment}-lt-"
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_pair_name

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.ec2.id]
  }

  user_data = base64encode(local.user_data)

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 enforced
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project_name}-${var.environment}-web"
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

###############################################################################
# NETWORK LOAD BALANCER, TARGET GROUP & LISTENERS
###############################################################################

resource "aws_lb" "web" {
  name               = "${var.project_name}-${var.environment}-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = module.vpc.public_subnets
  security_groups    = [aws_security_group.nlb.id]

  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = var.environment == "prod" ? true : false

  tags = {
    Name = "${var.project_name}-${var.environment}-nlb"
  }
}

resource "aws_lb_target_group" "web" {
  name        = "${var.project_name}-${var.environment}-tg"
  protocol    = "TCP"
  port        = 80
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = "80"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-tg"
  }
}

# The only listener. TLS ends at the NLB; the NLB forwards plain TCP to port 80
# on the instances inside the VPC. There is no port 80 listener: an NLB cannot
# redirect, so http:// requests to the hostname fail to connect.
#
# The certificate ARN comes from the validation resource, so this listener is
# created only after ACM has issued the certificate.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "TLS"
  certificate_arn   = aws_acm_certificate_validation.web.certificate_arn
  ssl_policy        = var.ssl_policy

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

###############################################################################
# TLS CERTIFICATE & DNS (ACM + CLOUDFLARE)
#
# Both Cloudflare records are DNS-only (not proxied), so browsers negotiate TLS
# with the NLB listener above. Cloudflare record names and values are written
# without the trailing dot that ACM returns.
###############################################################################

resource "aws_acm_certificate" "web" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  tags = {
    Name = "${var.project_name}-${var.environment}-cert"
  }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  # A certificate for a single name has exactly one validation record.
  acm_validation = one(aws_acm_certificate.web.domain_validation_options)
}

# ACM validation CNAME. ACM also uses this record to renew the certificate, so
# it must stay in place for as long as the certificate is in use.
resource "cloudflare_dns_record" "acm_validation" {
  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(local.acm_validation.resource_record_name, ".")
  type    = "CNAME"
  content = trimsuffix(local.acm_validation.resource_record_value, ".")
  ttl     = 300
  proxied = false
}

# Waits until ACM reports the certificate as issued.
resource "aws_acm_certificate_validation" "web" {
  certificate_arn = aws_acm_certificate.web.arn

  depends_on = [cloudflare_dns_record.acm_validation]
}

# Hostname CNAME to the NLB. The NLB DNS name changes every time the stack is
# destroyed and re-created, hence the short TTL.
resource "cloudflare_dns_record" "web" {
  zone_id = var.cloudflare_zone_id
  name    = var.domain_name
  type    = "CNAME"
  content = lower(aws_lb.web.dns_name)
  ttl     = 60
  proxied = false
}

###############################################################################
# AUTO SCALING GROUP
###############################################################################

resource "aws_autoscaling_group" "web" {
  name                      = "${var.project_name}-${var.environment}-asg"
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  vpc_zone_identifier       = module.vpc.private_subnets
  target_group_arns         = [aws_lb_target_group.web.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${var.environment}-web"
    propagate_at_launch = true
  }

  tag {
    key                 = "Project"
    value               = var.project_name
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

  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # Instances run the boot-time database check in user data, so the database
  # and the policy that lets the instance role read its secret must exist
  # before the first instance launches.
  depends_on = [
    aws_db_instance.main,
    aws_iam_role_policy.db_secret_read,
  ]
}

###############################################################################
# SCALING POLICIES
###############################################################################

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.project_name}-${var.environment}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.web.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = 300
  policy_type            = "SimpleScaling"
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "${var.project_name}-${var.environment}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.web.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = 300
  policy_type            = "SimpleScaling"
}

###############################################################################
# SNS TOPIC & SUBSCRIPTION
###############################################################################

resource "aws_sns_topic" "alarms" {
  name = "${var.project_name}-${var.environment}-alarms"
}

# The subscription requires manual email confirmation before alarms fire.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

###############################################################################
# CLOUDWATCH ALARMS
###############################################################################

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project_name}-${var.environment}-cpu-high"
  alarm_description   = "Scale out when average CPU exceeds ${var.cpu_scale_out_threshold}% for 2 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.cpu_scale_out_threshold
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_out.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.project_name}-${var.environment}-cpu-low"
  alarm_description   = "Scale in when average CPU falls below ${var.cpu_scale_in_threshold}% for 2 minutes"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.cpu_scale_in_threshold
  comparison_operator = "LessThanThreshold"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_in.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.project_name}-${var.environment}-unhealthy-hosts"
  alarm_description   = "Alert when NLB reports 1 or more unhealthy targets"
  namespace           = "AWS/NetworkELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    LoadBalancer = aws_lb.web.arn_suffix
    TargetGroup  = aws_lb_target_group.web.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "healthy_hosts" {
  alarm_name          = "${var.project_name}-${var.environment}-healthy-hosts-low"
  alarm_description   = "Alert when healthy host count drops below minimum"
  namespace           = "AWS/NetworkELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = var.asg_min_size
  comparison_operator = "LessThanThreshold"

  dimensions = {
    LoadBalancer = aws_lb.web.arn_suffix
    TargetGroup  = aws_lb_target_group.web.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "network_in_high" {
  alarm_name         = "${var.project_name}-${var.environment}-network-in-high"
  alarm_description  = "High inbound network traffic on NLB"
  namespace          = "AWS/NetworkELB"
  metric_name        = "ProcessedBytes"
  statistic          = "Sum"
  period             = 300
  evaluation_periods = 2
  # 1 GB per 5-minute period
  threshold           = 1073741824
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    LoadBalancer = aws_lb.web.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
}

###############################################################################
# WAF v2
#
# NOTE: WAFv2 Web ACL associations are only supported on Layer 7 resources
# (ALB, API Gateway, AppSync, Cognito, App Runner, Verified Access).
# Network Load Balancers operate at Layer 4 (TCP/TLS) and CANNOT be
# associated with a WAFv2 Web ACL — doing so causes a ValidationException
# during terraform apply.
#
# The ACL is created here so it is ready to associate with an ALB if you add
# one in front of this NLB later. To add WAF protection today, place an ALB
# in front of the NLB and associate this ACL with the ALB ARN.
###############################################################################

resource "aws_wafv2_web_acl" "main" {
  name  = "${var.project_name}-${var.environment}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-bad-inputs-rules"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-${var.environment}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-waf"
  }
}

# aws_wafv2_web_acl_association is intentionally omitted.
# WAFv2 cannot be associated with a Network Load Balancer (Layer 4).
# Associate this ACL with an ALB ARN if you add an ALB in front of the NLB.
