variable "host_project_id" {
  description = "Shared VPC host project ID."
  type        = string
}

variable "prod_service_project_id" {
  description = "Service project for production workloads."
  type        = string
}

variable "nonprod_service_project_id" {
  description = "Service project for staging and dev workloads."
  type        = string
}

variable "terraform_sa_email" {
  description = "Service account Terraform impersonates."
  type        = string
}

variable "primary_region" {
  description = "Primary region."
  type        = string
  default     = "us-central1"
}

variable "secondary_region" {
  description = "Secondary region (prod DR)."
  type        = string
  default     = "us-east1"
}

variable "bgp_asn" {
  description = "Private ASN for Cloud Routers on the Google side."
  type        = number
  default     = 64512
}
