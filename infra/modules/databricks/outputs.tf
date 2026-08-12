output "warehouse_id" {
  value = databricks_sql_endpoint.main.id
}

output "storage_credential_external_id" {
  value = databricks_storage_credential.raw.aws_iam_role[0].external_id
}
