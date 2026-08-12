variable "project" {
  type    = string
  default = "sc2obs"
}

variable "aws_region" {
  type    = string
  default = "eu-west-1"
}

variable "databricks_host" {
  type = string
}

variable "databricks_free_edition" {
  type    = bool
  default = false
}

variable "databricks_storage_credential_external_id" {
  description = "External ID from the Unity Catalog storage credential (two-phase apply, see README)"
  type        = string
  default     = "0000"
}

variable "git_url" {
  description = "HTTPS URL of this repo, used by Databricks jobs"
  type        = string
}

variable "git_branch" {
  type    = string
  default = "main"
}
