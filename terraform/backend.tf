# Remote state in a private, versioned GCS bucket (created by scripts/03-shared-vpc-prereqs.sh).
# Backend blocks cannot use variables, so values are set here directly.
terraform {
  backend "gcs" {
    bucket                      = "saas-vpc-host-2022-tfstate"
    prefix                      = "network"
    impersonate_service_account = "network-admin-sa@saas-vpc-host-2022.iam.gserviceaccount.com"
  }
}
