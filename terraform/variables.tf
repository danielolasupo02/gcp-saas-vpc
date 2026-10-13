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

variable "fintech_project_id" {
  description = "Tenant project for the fintech customer."
  type        = string
}

variable "health_project_id" {
  description = "Tenant project for the healthcare customer."
  type        = string
}

variable "org_id" {
  description = "Organization ID (for hierarchical firewall policy and org policies)."
  type        = string
}

variable "onprem_bgp_asn" {
  description = "Private ASN for the simulated on-prem Cloud Router."
  type        = number
  default     = 64513
}

variable "enable_hybrid_vpn" {
  description = "Create the HA VPN to the simulated on-prem network. Set false to remove it and stop tunnel charges."
  type        = bool
  default     = true
}
