locals {
  databricks_aws_account = "414351767826"
  role_name              = "${var.project}-uc-access"
  full                   = var.free_edition ? 0 : 1

  warehouse_id = var.free_edition ? data.databricks_sql_warehouse.starter[0].id : databricks_sql_endpoint.main[0].id
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
  count = local.full

  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.uc_assume.json
}

resource "aws_iam_role_policy" "uc" {
  count = local.full

  role   = aws_iam_role.uc[0].id
  policy = data.aws_iam_policy_document.uc_access.json
}

resource "databricks_storage_credential" "raw" {
  count = local.full

  name = "${var.project}-raw"

  aws_iam_role {
    role_arn = aws_iam_role.uc[0].arn
  }
}

resource "databricks_external_location" "raw" {
  count = local.full

  name            = "${var.project}-raw"
  url             = "s3://${var.bucket}/raw"
  credential_name = databricks_storage_credential.raw[0].name
}

resource "databricks_catalog" "sc2" {
  name    = "sc2"
  comment = "SC2 Balance Observatory"

  # Free Edition catalogs are created in the UI with Default Storage;
  # never let a storage_root diff force a replacement
  lifecycle {
    ignore_changes = [storage_root, properties, options]
  }
}

resource "databricks_schema" "layer" {
  for_each = toset(["bronze", "silver", "gold"])

  catalog_name = databricks_catalog.sc2.name
  name         = each.key
}

# Free Edition: managed volume, synced from S3 manually.
# Full mode: external volume over s3://<bucket>/raw — same /Volumes path either way.
resource "databricks_volume" "raw" {
  catalog_name     = databricks_catalog.sc2.name
  schema_name      = databricks_schema.layer["bronze"].name
  name             = "raw"
  volume_type      = var.free_edition ? "MANAGED" : "EXTERNAL"
  storage_location = var.free_edition ? null : "s3://${var.bucket}/raw"

  depends_on = [databricks_external_location.raw]
}

# Free Edition allows exactly one warehouse: reuse the built-in starter
data "databricks_sql_warehouse" "starter" {
  count = var.free_edition ? 1 : 0

  name = "Serverless Starter Warehouse"
}

resource "databricks_sql_endpoint" "main" {
  count = local.full

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

  dynamic "task" {
    for_each = {
      bronze = { file = "databricks/sql/bronze.sql", depends = null }
      silver = { file = "databricks/sql/silver.sql", depends = "bronze" }
      gold   = { file = "databricks/sql/gold.sql", depends = "silver" }
    }

    content {
      task_key = task.key

      sql_task {
        warehouse_id = local.warehouse_id

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
