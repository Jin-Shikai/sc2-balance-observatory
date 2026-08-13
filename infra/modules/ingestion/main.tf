locals {
  functions = {
    pulse_snapshot = {
      schedule = null # on demand only; not needed for the published page
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
      schedule = null # reconciliation done; on demand only
      timeout  = 300
    }
    volume_sync = {
      schedule = null # S3 event driven
      timeout  = 120
    }
  }

  scheduled = { for k, v in local.functions : k => v if v.schedule != null }
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

resource "aws_secretsmanager_secret" "databricks" {
  name = "${var.project}/databricks"
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
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${var.bucket_arn}/raw/*"]
  }

  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.blizzard.arn,
      aws_secretsmanager_secret.aligulac.arn,
      aws_secretsmanager_secret.databricks.arn,
    ]
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
      BUCKET                = var.bucket
      BLIZZARD_SECRET_ARN   = aws_secretsmanager_secret.blizzard.arn
      ALIGULAC_SECRET_ARN   = aws_secretsmanager_secret.aligulac.arn
      DATABRICKS_SECRET_ARN = aws_secretsmanager_secret.databricks.arn
    }
  }
}

resource "aws_cloudwatch_event_rule" "fn" {
  for_each = local.scheduled

  name                = "${var.project}-${each.key}"
  schedule_expression = each.value.schedule
}

resource "aws_cloudwatch_event_target" "fn" {
  for_each = local.scheduled

  rule = aws_cloudwatch_event_rule.fn[each.key].name
  arn  = aws_lambda_function.fn[each.key].arn
}

resource "aws_lambda_permission" "events" {
  for_each = local.scheduled

  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.key].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.fn[each.key].arn
}

resource "aws_lambda_permission" "s3" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["volume_sync"].function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.bucket_arn
}

resource "aws_s3_bucket_notification" "raw" {
  bucket = var.bucket

  lambda_function {
    lambda_function_arn = aws_lambda_function.fn["volume_sync"].arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw/"
  }

  depends_on = [aws_lambda_permission.s3]
}
