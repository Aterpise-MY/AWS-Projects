terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
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

# =============================================================================
# DATA SOURCES
# =============================================================================

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

# Resolve the latest Amazon Linux 2 AMI in the target region at plan time.
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-2.*-x86_64-gp2"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# =============================================================================
# SECURITY GROUP
# =============================================================================

resource "aws_security_group" "web" {
  name        = "${var.app_name}-sg"
  description = "Allow SSH, HTTP, HTTPS inbound; all outbound"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.app_name}-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.web.id
  description       = "SSH"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.web.id
  description       = "HTTP"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  security_group_id = aws_security_group.web.id
  description       = "HTTPS"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  security_group_id = aws_security_group.web.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# =============================================================================
# LAUNCH TEMPLATE
# =============================================================================

locals {
  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
    systemctl enable httpd
    systemctl start httpd

    # Fetch instance metadata using IMDSv2
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/instance-id)
    AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
      http://169.254.169.254/latest/meta-data/placement/availability-zone)

    cat > /var/www/html/index.html <<HTML
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
      </div>
    </body>
    </html>
    HTML
  EOF
  )
}

resource "aws_launch_template" "web" {
  name                   = "${var.app_name}Template"
  image_id               = data.aws_ami.amazon_linux_2.id
  instance_type          = var.instance_type
  key_name               = var.key_pair_name
  vpc_security_group_ids = [aws_security_group.web.id]
  user_data              = local.user_data

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
# ALB — LOAD BALANCER & LISTENER
# =============================================================================

resource "aws_lb" "web" {
  name               = "${var.app_name}ALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web.id]
  subnets            = local.all_subnet_ids

  enable_deletion_protection = false

  tags = {
    Name = "${var.app_name}ALB"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
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
  name                   = "${var.app_name}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.web.name
  adjustment_type        = "ChangeInCapacity"
  policy_type            = "StepScaling"
  metric_aggregation_type = "Average"

  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0   # CPU between threshold and threshold+20
    metric_interval_upper_bound = 20
  }

  step_adjustment {
    scaling_adjustment          = 2
    metric_interval_lower_bound = 20  # CPU more than threshold+20 (sustained spike)
  }
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "${var.app_name}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.web.name
  adjustment_type        = "ChangeInCapacity"
  policy_type            = "StepScaling"
  metric_aggregation_type = "Average"

  step_adjustment {
    scaling_adjustment          = -1
    metric_interval_upper_bound = 0   # CPU below threshold
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
