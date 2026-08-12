output "raw_bucket" {
  value = module.storage.bucket_name
}

output "secret_arns" {
  value = module.ingestion.secret_arns
}

output "sql_warehouse_id" {
  value = module.databricks.warehouse_id
}
