mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_resource "aws_lambda_function" {
    defaults = {
      arn = "arn:aws:lambda:ca-central-1:111111111111:function:resource-scheduler"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111111111111:role/resource-scheduler"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:ca-central-1:111111111111:log-group:/aws/lambda/resource-scheduler"
    }
  }
}

run "defaults" {
  command = apply

  assert {
    condition     = aws_scheduler_schedule.this["start"].schedule_expression_timezone == "America/Toronto"
    error_message = "Schedules should default to Toronto time."
  }

  assert {
    condition     = jsondecode(aws_scheduler_schedule.this["stop"].target[0].input).action == "stop"
    error_message = "Stop schedule must send action=stop."
  }

  assert {
    condition     = aws_scheduler_schedule.this["start"].state == "ENABLED"
    error_message = "Schedules should be enabled by default."
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables.DRY_RUN == "false"
    error_message = "Dry run should be off by default."
  }
}

run "paused_and_dry_run" {
  command = apply

  variables {
    schedules_enabled = false
    dry_run           = true
    enable_ecs        = false
  }

  assert {
    condition     = alltrue([for s in aws_scheduler_schedule.this : s.state == "DISABLED"])
    error_message = "schedules_enabled = false should disable both schedules."
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables.ENABLE_ECS == "false"
    error_message = "enable_ecs should flow through to the function."
  }
}

run "rejects_bad_name" {
  command = plan

  variables {
    name = "has spaces"
  }

  expect_failures = [var.name]
}
