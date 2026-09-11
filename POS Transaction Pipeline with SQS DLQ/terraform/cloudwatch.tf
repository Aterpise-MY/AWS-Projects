###############################################################################
# CloudWatch dashboard
#
# Phase 4 deliverable (§8): source queue depth + DLQ depth + Lambda errors, on
# one screen, so the on-call engineer can answer "which lane broke, and is it
# getting worse?" without clicking through three queue consoles.
#
# The per-DLQ alarms live in module "consumer_queue" alongside the queue they
# watch; only the cross-lane view is defined here.
###############################################################################

locals {
  dashboard_name = "${var.name_prefix}-dlq-pipeline"

  # Deterministic ordering so the dashboard JSON (and therefore the plan diff)
  # is stable across runs. `local.consumers` is a map, which Terraform iterates
  # in lexical key order, but being explicit keeps loyalty first to match the
  # narrative order used everywhere else in the project.
  lane_order = ["loyalty", "inventory", "einvoice"]

  source_queue_names = [for k in local.lane_order : local.consumers[k].source_queue_name]
  dlq_names          = [for k in local.lane_order : local.consumers[k].dlq_name]
  function_names     = [for k in local.lane_order : local.consumers[k].lambda_function_name]
}

resource "aws_cloudwatch_dashboard" "pipeline" {
  dashboard_name = local.dashboard_name

  dashboard_body = jsonencode({
    widgets = [

      # ---------------------------------------------------------------------
      # Widget 1 — source queue backlog.
      # Rising depth across ALL three lanes means the publisher is outrunning
      # the consumers. Rising depth in ONE lane means that downstream
      # dependency is degraded.
      # ---------------------------------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Source queue backlog - ApproximateNumberOfMessagesVisible"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          stat    = "Maximum"
          period  = 60
          metrics = [
            for name in local.source_queue_names :
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", name]
          ]
          yAxis = {
            left = {
              label     = "Messages"
              showUnits = false
              min       = 0
            }
          }
        }
      },

      # ---------------------------------------------------------------------
      # Widget 2 — DLQ depth. Anything above zero here is an unprocessed
      # transaction and a live incident (R1). Annotated at 1 to match the
      # `<lane>-dlq-not-empty` alarm threshold.
      # ---------------------------------------------------------------------
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "DLQ depth - ApproximateNumberOfMessagesVisible (any value > 0 is an incident)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          stat    = "Maximum"
          period  = 60
          metrics = [
            for name in local.dlq_names :
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", name]
          ]
          yAxis = {
            left = {
              label     = "Messages"
              showUnits = false
              min       = 0
            }
          }
          annotations = {
            horizontal = [
              {
                label = "dlq-not-empty alarm threshold"
                value = 1
                fill  = "above"
              }
            ]
          }
        }
      },

      # ---------------------------------------------------------------------
      # Widget 3 — consumer health. Errors plotted against Invocations so a
      # spike can be read as a rate, not an absolute: 50 errors out of 50
      # invocations is an outage, 50 out of 25,000 is a handful of poison
      # messages.
      # ---------------------------------------------------------------------
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "Consumer Lambda - Errors vs Invocations"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          stat    = "Sum"
          period  = 60
          metrics = concat(
            [
              for name in local.function_names :
              ["AWS/Lambda", "Errors", "FunctionName", name, { color = "#d62728" }]
            ],
            [
              for name in local.function_names :
              ["AWS/Lambda", "Invocations", "FunctionName", name, { color = "#1f77b4" }]
            ],
          )
          yAxis = {
            left = {
              label     = "Count"
              showUnits = false
              min       = 0
            }
          }
        }
      },

      # ---------------------------------------------------------------------
      # Widget 4 — how close the oldest DLQ message is to permanent loss.
      # For a Standard queue this age is measured from the ORIGINAL enqueue on
      # the source queue and is NOT reset by the move to the DLQ, so it is the
      # true countdown against the 14-day retention limit. Annotated at the
      # 7-day alarm threshold and at the 14-day deletion cliff.
      # ---------------------------------------------------------------------
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "DLQ message age - ApproximateAgeOfOldestMessage (seconds)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          stat    = "Maximum"
          period  = 300
          metrics = [
            for name in local.dlq_names :
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", name]
          ]
          yAxis = {
            left = {
              label     = "Seconds"
              showUnits = false
              min       = 0
            }
          }
          annotations = {
            horizontal = [
              {
                label = "7d - dlq-message-aging alarm"
                value = 604800
              },
              {
                label = "14d - SQS deletes the message"
                value = 1209600
                fill  = "above"
              }
            ]
          }
        }
      },
    ]
  })
}
