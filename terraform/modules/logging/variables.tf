variable "project_id" {
  description = "Central logging project: owns the archive bucket and the flow-log dataset."
  type        = string
}

variable "location" {
  description = "Location for the archive bucket and BigQuery dataset."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for bucket, dataset and sink names."
  type        = string
  default     = "network"
}

variable "source_projects" {
  description = "Projects whose network logs are exported, keyed by a short name (e.g. host, fintech)."
  type        = map(string)
}

variable "terraform_sa_email" {
  description = "Terraform's identity. Changes made by it are expected; changes by anyone else are flagged."
  type        = string
}

variable "flow_log_table_expiration_days" {
  description = "Days to keep partitions in the BigQuery flow-log tables (hot analytics)."
  type        = number
  default     = 30
}

variable "archive_coldline_after_days" {
  description = "Move archived audit logs to Coldline after this many days."
  type        = number
  default     = 30
}

variable "archive_delete_after_days" {
  description = "Delete archived audit logs after this many days."
  type        = number
  default     = 365

  validation {
    condition     = var.archive_delete_after_days > var.archive_coldline_after_days
    error_message = "archive_delete_after_days must be greater than archive_coldline_after_days."
  }
}

variable "enable_log_analytics" {
  description = "Upgrade the central project's _Default log bucket to Log Analytics (needed for Flow Analyzer). One-way change."
  type        = bool
  default     = true
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete the archive bucket and dataset with data in them (lab only)."
  type        = bool
  default     = true
}
