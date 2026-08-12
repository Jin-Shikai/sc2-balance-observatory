locals {
  functions = {
    pulse_snapshot = {
      schedule = "cron(5 * * * ? *)"
      timeout  = 120
    }
    pulse_daily = {
      schedule = "cron(20 2 * * ? *)"
      timeout  = 900
    }
    aligulac_daily = {
      schedule = "cron(40 2 * * ? *)"
      timeout  = 600
    }
    blizzard_daily = {
      schedule = "cron(0 3 * * ? *)"
      timeout  = 300
    }
  }
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = var.lambda_src
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_secretsmanager_secret" "blizzard" {
  name = "${var.project}/blizzard"
}

resource "aws_secretsmanager_secret" "aligulac" {
  name = "${var.project}/aligulac"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project}-ingestion"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "lambda" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${var.bucket_arn}/raw/*"]
  }

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.blizzard.arn, aws_secretsmanager_secret.aligulac.arn]
  }

  statement {
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

resource "aws_iam_role_policy" "lambda" {
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

resource "aws_lambda_function" "fn" {
  for_each = local.functions

  function_name    = "${var.project}-${each.key}"
  role             = aws_iam_role.lambda.arn
  handler          = "observatory.handlers.${each.key}.handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  memory_size      = 256
  timeout          = each.value.timeout
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      BUCKET              = var.bucket
      BLIZZARD_SECRET_ARN = aws_secretsmanager_secret.blizzard.arn
      ALIGULAC_SECRET_ARN = aws_secretsmanager_secret.aligulac.arn
    }
  }
}

resource "aws_cloudwatch_event_rule" "fn" {
  for_each = local.functions

  name                = "${var.project}-${each.key}"
  schedule_expression = each.value.schedule
}

resource "aws_cloudwatch_event_target" "fn" {
  for_each = local.functions

  rule = aws_cloudwatch_event_rule.fn[each.key].name
  arn  = aws_lambda_function.fn[each.key].arn
}

resource "aws_lambda_permission" "events" {
  for_each = local.functions

  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.fn[each.key].arn
}
