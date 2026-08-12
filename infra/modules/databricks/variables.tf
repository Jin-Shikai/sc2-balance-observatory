variable "project" {
  type = string
}

variable "free_edition" {
  description = "Databricks Free Edition: reuse the starter warehouse, skip S3 storage credential, use a managed volume"
  type        = bool
  default     = false
}

variable "bucket" {
  type = string
}

variable "bucket_arn" {
  type = string
}

variable "storage_credential_external_id" {
  type = string
}

variable "git_url" {
  type = string
}

variable "git_branch" {
  type = string
}
