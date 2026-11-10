locals {
  # Mutating calls are only allowed on resources that carry the schedule tag.
  tag_condition = {
    test     = "StringEquals"
    variable = "aws:ResourceTag/${var.schedule_tag_key}"
    values   = [var.schedule_tag_value]
  }
}

data "aws_partition" "current" {}

# ---------- Lambda package ----------

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/src/scheduler.py"
  output_path = "${path.module}/.build/scheduler.zip"
}

# ---------- Lambda execution role ----------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda.arn}:*"]
  }

  dynamic "statement" {
    for_each = var.enable_ec2 ? [1] : []
    content {
      sid       = "Ec2Describe"
      actions   = ["ec2:DescribeInstances"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_ec2 ? [1] : []
    content {
      sid       = "Ec2StartStop"
      actions   = ["ec2:StartInstances", "ec2:StopInstances"]
      resources = ["arn:${data.aws_partition.current.partition}:ec2:*:*:instance/*"]
      condition {
        test     = local.tag_condition.test
        variable = local.tag_condition.variable
        values   = local.tag_condition.values
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_ec2 && length(var.kms_key_arns) > 0 ? [1] : []
    content {
      sid       = "KmsForEncryptedVolumes"
      actions   = ["kms:CreateGrant"]
      resources = var.kms_key_arns
      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_rds ? [1] : []
    content {
      sid       = "RdsDescribe"
      actions   = ["rds:DescribeDBInstances", "rds:DescribeDBClusters"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_rds ? [1] : []
    content {
      sid = "RdsStartStop"
      actions = [
        "rds:StartDBInstance",
        "rds:StopDBInstance",
        "rds:StartDBCluster",
        "rds:StopDBCluster",
      ]
      resources = [
        "arn:${data.aws_partition.current.partition}:rds:*:*:db:*",
        "arn:${data.aws_partition.current.partition}:rds:*:*:cluster:*",
      ]
      condition {
        test     = local.tag_condition.test
        variable = local.tag_condition.variable
        values   = local.tag_condition.values
      }
    }
  }

  dynamic "statement" {
    for_each = var.enable_ecs ? [1] : []
    content {
      sid       = "EcsDescribe"
      actions   = ["ecs:ListClusters", "ecs:ListServices", "ecs:DescribeServices"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_ecs ? [1] : []
    content {
      sid       = "EcsScale"
      actions   = ["ecs:UpdateService", "ecs:TagResource"]
      resources = ["arn:${data.aws_partition.current.partition}:ecs:*:*:service/*"]
      condition {
        test     = local.tag_condition.test
        variable = local.tag_condition.variable
        values   = local.tag_condition.values
      }
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name}-lambda"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# ---------- Lambda function ----------

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "this" {
  function_name    = var.name
  description      = "Starts and stops resources tagged ${var.schedule_tag_key}=${var.schedule_tag_value}"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "scheduler.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 300
  memory_size      = 256

  environment {
    variables = {
      SCHEDULE_TAG_KEY   = var.schedule_tag_key
      SCHEDULE_TAG_VALUE = var.schedule_tag_value
      ENABLE_EC2         = tostring(var.enable_ec2)
      ENABLE_RDS         = tostring(var.enable_rds)
      ENABLE_ECS         = tostring(var.enable_ecs)
      DRY_RUN            = tostring(var.dry_run)
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy.lambda]
  tags       = var.tags
}

# ---------- EventBridge Scheduler ----------

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.this.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "${var.name}-invoke"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

locals {
  schedules = {
    start = var.start_schedule
    stop  = var.stop_schedule
  }
}

resource "aws_scheduler_schedule" "this" {
  for_each = local.schedules

  name                         = "${var.name}-${each.key}"
  description                  = "${title(each.key)} resources tagged ${var.schedule_tag_key}=${var.schedule_tag_value}"
  schedule_expression          = each.value
  schedule_expression_timezone = var.timezone
  state                        = var.schedules_enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.this.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = each.key })

    retry_policy {
      maximum_retry_attempts = 2
    }
  }
}
