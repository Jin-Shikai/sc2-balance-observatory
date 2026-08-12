module "storage" {
  source  = "./modules/storage"
  project = var.project
}

module "ingestion" {
  source     = "./modules/ingestion"
  project    = var.project
  bucket     = module.storage.bucket_name
  bucket_arn = module.storage.bucket_arn
  lambda_src = "${path.root}/../ingestion/src"
}

module "databricks" {
  source                         = "./modules/databricks"
  project                        = var.project
  free_edition                   = var.databricks_free_edition
  bucket                         = module.storage.bucket_name
  bucket_arn                     = module.storage.bucket_arn
  storage_credential_external_id = var.databricks_storage_credential_external_id
  git_url                        = var.git_url
  git_branch                     = var.git_branch
}
