output "warehouse_id" {
  value = local.warehouse_id
}

output "storage_credential_external_id" {
  value = var.free_edition ? null : databricks_storage_credential.raw[0].aws_iam_role[0].external_id
}
