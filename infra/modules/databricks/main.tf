locals {
  databricks_aws_account = "414351767826"
  role_name              = "${var.project}-uc-access"
}

data "aws_caller_identity" "this" {}

data "aws_iam_policy_document" "uc_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.databricks_aws_account}:root"]
    }

    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.storage_credential_external_id]
    }
  }

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.this.account_id}:root"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::${data.aws_caller_identity.this.account_id}:role/${local.role_name}"]
    }
  }
}

data "aws_iam_policy_document" "uc_access" {
  statement {
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [var.bucket_arn, "${var.bucket_arn}/*"]
  }
}

resource "aws_iam_role" "uc" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.uc_assume.json
}

resource "aws_iam_role_policy" "uc" {
  role   = aws_iam_role.uc.id
  policy = data.aws_iam_policy_document.uc_access.json
}

resource "databricks_storage_credential" "raw" {
  name = "${var.project}-raw"

  aws_iam_role {
    role_arn = aws_iam_role.uc.arn
  }
}

resource "databricks_external_location" "raw" {
  name            = "${var.project}-raw"
  url             = "s3://${var.bucket}/raw"
  credential_name = databricks_storage_credential.raw.name
}

resource "databricks_catalog" "sc2" {
  name    = "sc2"
  comment = "SC2 Balance Observatory"
}

resource "databricks_schema" "layer" {
  for_each = toset(["bronze", "silver", "gold"])

  catalog_name = databricks_catalog.sc2.name
  name         = each.key
}

resource "databricks_sql_endpoint" "main" {
  name                      = "${var.project}-wh"
  cluster_size              = "2X-Small"
  auto_stop_mins            = 5
  max_num_clusters          = 1
  enable_serverless_compute = true
}

resource "databricks_job" "medallion" {
  name = "${var.project}-medallion-refresh"

  git_source {
    url      = var.git_url
    provider = "gitHub"
    branch   = var.git_branch
  }

  schedule {
    quartz_cron_expression = "0 0 4 * * ?"
    timezone_id            = "UTC"
  }

  parameter {
    name    = "raw_root"
    default = "s3://${var.bucket}/raw"
  }

  dynamic "task" {
    for_each = {
      bronze = { file = "databricks/sql/bronze.sql", depends = null }
      silver = { file = "databricks/sql/silver.sql", depends = "bronze" }
      gold   = { file = "databricks/sql/gold.sql", depends = "silver" }
    }

    content {
      task_key = task.key

      sql_task {
        warehouse_id = databricks_sql_endpoint.main.id

        file {
          path   = task.value.file
          source = "GIT"
        }
      }

      dynamic "depends_on" {
        for_each = task.value.depends == null ? [] : [task.value.depends]

        content {
          task_key = depends_on.value
        }
      }
    }
  }
}
