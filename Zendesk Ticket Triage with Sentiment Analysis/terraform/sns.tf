resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-negative-alerts"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-negative-alerts"
  })
}

# Optional email subscription — created only when alert_email is non-empty.
# The subscriber must confirm the subscription via the email AWS sends.
resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
