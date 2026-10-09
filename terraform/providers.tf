# All changes run as the network admin service account via impersonation.
# No service account keys are used anywhere.
provider "google" {
  project                     = var.host_project_id
  region                      = var.primary_region
  impersonate_service_account = var.terraform_sa_email
}
