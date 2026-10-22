# Offline plan-level checks (mocked AWS provider, no credentials, no apply).
# Run: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  ebteqdesk_base_url = "https://ebteqdesk.example.com"
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_scheduler_schedule.sync["salonv3"].state == "ENABLED" && aws_scheduler_schedule.sync["warni"].state == "DISABLED"
    error_message = "Salon V3 must be ENABLED and Warni DISABLED by default."
  }
  assert {
    condition     = aws_scheduler_schedule.sync["salonv3"].schedule_expression == "cron(0 9-17 ? * MON-FRI *)" && aws_scheduler_schedule.sync["warni"].schedule_expression == "cron(30 9-16 ? * MON-FRI *)"
    error_message = "Sync schedules must be weekday office hours."
  }
  assert {
    condition     = alltrue([for s in aws_scheduler_schedule.sync : s.schedule_expression_timezone == "Asia/Kuala_Lumpur"])
    error_message = "Every sync schedule must use Asia/Kuala_Lumpur."
  }
  assert {
    condition     = aws_scheduler_schedule.daily_report.schedule_expression == "cron(0 18 ? * MON-FRI *)"
    error_message = "Daily report must run weekdays 18:00."
  }
  assert {
    condition     = strcontains(aws_scheduler_schedule.sync["warni"].target[0].input, "\"<aws.scheduler.scheduled-time>\"")
    error_message = "Scheduler input must keep raw <aws.scheduler.*> placeholders (heredoc, not jsonencode)."
  }
  assert {
    condition     = aws_lambda_function.runner.environment[0].variables.ALLOWED_PORTALS == "salonv3,warni"
    error_message = "Runner must allow every brand, including disabled ones, for manual tests."
  }
  assert {
    condition     = aws_sqs_queue.trigger.visibility_timeout_seconds == 900 && var.max_receive_count == 2
    error_message = "Retry model must be visibility 900 s and maxReceiveCount 2."
  }
  assert {
    condition     = aws_lambda_function.runner.timeout == 600
    error_message = "Runner timeout must default to 600 s."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.report_not_generated.evaluation_periods * aws_cloudwatch_metric_alarm.report_not_generated.period <= 604800
    error_message = "Reporter alarm window must fit CloudWatch's 7-day limit."
  }
  assert {
    condition     = aws_lambda_function_event_invoke_config.reporter.maximum_retry_attempts == 2
    error_message = "Reporter async retries must be 2."
  }
}

run "enable_warni_only_flips_its_schedule" {
  command = plan

  variables {
    portals = {
      salonv3 = { schedule_expression = "cron(0 9-17 ? * MON-FRI *)", enabled = true, expected_runs_per_day = 9 }
      warni   = { schedule_expression = "cron(30 9-16 ? * MON-FRI *)", enabled = true, expected_runs_per_day = 8 }
    }
  }

  assert {
    condition     = aws_scheduler_schedule.sync["warni"].state == "ENABLED" && aws_scheduler_schedule.sync["salonv3"].state == "ENABLED"
    error_message = "Enabling Warni must set its schedule ENABLED."
  }
  assert {
    condition     = aws_lambda_function.runner.environment[0].variables.ALLOWED_PORTALS == "salonv3,warni"
    error_message = "ALLOWED_PORTALS must not depend on enabled."
  }
}

run "rejects_unknown_portal" {
  command = plan

  variables {
    portals = {
      salonv4 = { schedule_expression = "cron(0 9 ? * MON-FRI *)", enabled = true, expected_runs_per_day = 1 }
    }
  }

  expect_failures = [var.portals]
}

run "rejects_bad_expression" {
  command = plan

  variables {
    portals = {
      salonv3 = { schedule_expression = "0 9 * * *", enabled = true, expected_runs_per_day = 1 }
    }
  }

  expect_failures = [var.portals]
}

run "rejects_visibility_below_timeout" {
  command = plan

  variables {
    lambda_timeout_seconds     = 600
    visibility_timeout_seconds = 300
  }

  expect_failures = [var.visibility_timeout_seconds]
}
