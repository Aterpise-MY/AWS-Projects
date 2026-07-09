# ===========================================================================
# observability module — Phase 6 CloudWatch + AD Connector.
# ---------------------------------------------------------------------------
# * SNS alarms topic (+ optional email subscription).
# * A single-pane CloudWatch dashboard: ALB, ECS service, and RDS health.
# * Metric alarms on ALB 5XX / latency / unhealthy hosts, ECS CPU+memory, and
#   RDS CPU / free storage / connections — all notifying the SNS topic.
# * AD Connector (gated): deploy-ready but OFF by default, since it needs
#   Site-to-Site VPN connectivity to the on-prem DCs and a populated bind
#   secret (real artifacts) before it can succeed.
# ===========================================================================

# ------------------------------- SNS topic ---------------------------------
# Left with default (SSE-off) encryption deliberately: a CMK-encrypted SNS
# topic would need the key policy to grant cloudwatch.amazonaws.com
# kms:GenerateDataKey/Decrypt, which the Phase 0 CMK does not. Encrypt later by
# adding that grant to modules/kms and setting kms_master_key_id here.
resource "aws_sns_topic" "alarms" {
  name = "${var.name_prefix}-alarms"

  tags = { Name = "${var.name_prefix}-alarms" }
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------- CloudWatch dashboard -------------------------
resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name_prefix

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "ALB — requests & 5XX"
          region  = var.region
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ALB — target response time (p95)"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p95" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ECS — CPU & memory utilisation"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { stat = "Average" }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name, { stat = "Average" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "RDS — CPU, connections & free storage"
          region = var.region
          view   = "timeSeries"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average" }],
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average" }]
          ]
        }
      }
    ]
  })
}

# ------------------------------- Alarms ------------------------------------
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name_prefix}-alb-5xx-high"
  alarm_description   = "ALB target 5XX responses elevated."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  tags = { Name = "${var.name_prefix}-alb-5xx-high" }
}

resource "aws_cloudwatch_metric_alarm" "alb_latency" {
  alarm_name          = "${var.name_prefix}-alb-latency-high"
  alarm_description   = "ALB target response time above 2s (p95)."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 3
  threshold           = 2
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  alarm_actions       = [aws_sns_topic.alarms.arn]

  tags = { Name = "${var.name_prefix}-alb-latency-high" }
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${var.name_prefix}-alb-unhealthy-hosts"
  alarm_description   = "One or more targets unhealthy."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }
  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = { Name = "${var.name_prefix}-alb-unhealthy-hosts" }
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${var.name_prefix}-ecs-cpu-high"
  alarm_description   = "ECS service CPU utilisation above 80%."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }
  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = { Name = "${var.name_prefix}-ecs-cpu-high" }
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name          = "${var.name_prefix}-ecs-memory-high"
  alarm_description   = "ECS service memory utilisation above 80%."
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }
  alarm_actions = [aws_sns_topic.alarms.arn]

  tags = { Name = "${var.name_prefix}-ecs-memory-high" }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS CPU utilisation above 80%."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  alarm_actions       = [aws_sns_topic.alarms.arn]

  tags = { Name = "${var.name_prefix}-rds-cpu-high" }
}

# 2 GiB in bytes — alert before the db.t4g.micro storage runs out.
resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "${var.name_prefix}-rds-free-storage-low"
  alarm_description   = "RDS free storage below 2 GiB."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  alarm_actions       = [aws_sns_topic.alarms.arn]

  tags = { Name = "${var.name_prefix}-rds-free-storage-low" }
}

resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.name_prefix}-rds-connections-high"
  alarm_description   = "RDS database connections elevated."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { DBInstanceIdentifier = var.db_instance_id }
  alarm_actions       = [aws_sns_topic.alarms.arn]

  tags = { Name = "${var.name_prefix}-rds-connections-high" }
}

# ===========================================================================
# AD Connector (gated) — deploy-ready, NOT applied by default.
# ---------------------------------------------------------------------------
# Requires a Site-to-Site VPN (or equivalent) so the connector ENIs can reach
# the on-prem domain controllers at ad_dns_ips (10.247.x.x), and a bind-account
# secret populated with {username,password}. Building the full VPN is out of
# scope here; this is the "written deploy-ready but not applied" piece.
# ===========================================================================
data "aws_secretsmanager_secret_version" "ad_bind" {
  count     = var.enable_ad_connector ? 1 : 0
  secret_id = var.ad_bind_secret_arn
}

locals {
  ad_bind = var.enable_ad_connector ? jsondecode(data.aws_secretsmanager_secret_version.ad_bind[0].secret_string) : null
}

resource "aws_directory_service_directory" "ad_connector" {
  count    = var.enable_ad_connector ? 1 : 0
  name     = var.ad_directory_name
  password = local.ad_bind.password
  size     = "Small"
  type     = "ADConnector"

  connect_settings {
    customer_dns_ips  = var.ad_dns_ips
    customer_username = local.ad_bind.username
    vpc_id            = var.ad_vpc_id
    subnet_ids        = var.ad_subnet_ids
  }

  tags = { Name = "${var.name_prefix}-ad-connector" }
}
