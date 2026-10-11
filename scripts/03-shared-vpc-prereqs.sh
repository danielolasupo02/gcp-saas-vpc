#!/usr/bin/env bash
# Phase 3 prerequisites
#  - Creates the service and tenant projects from the Phase 2 design
#  - Removes auto-created "default" networks (permissive firewall rules)
#  - Grants the Terraform service account the org/project roles it needs
#  - Creates a versioned, private GCS bucket for Terraform remote state
#
# Run as your own user (org admin) in Cloud Shell. Safe to re-run.
set -euo pipefail

ORG_ID="172544480375"
HOST_PROJECT="saas-vpc-host-2022"
BILLING_ACCOUNT="XXXXXX-XXXXXX-XXXXXX"   # <-- your OPEN billing account ID
REGION="us-central1"
SA_EMAIL="network-admin-sa@${HOST_PROJECT}.iam.gserviceaccount.com"
STATE_BUCKET="${HOST_PROJECT}-tfstate"

SERVICE_PROJECTS=(saas-svc-prod-2022 saas-svc-nonprod-2022)
TENANT_PROJECTS=(saas-tenant-fintech-2022 saas-tenant-health-2022)

log() { printf '\n==> %s\n' "$*"; }

# --- 1. Create projects, link billing, enable APIs ----------------------------
for P in "${SERVICE_PROJECTS[@]}" "${TENANT_PROJECTS[@]}"; do
  if gcloud projects describe "$P" >/dev/null 2>&1; then
    log "Project $P already exists"
  else
    log "Creating project $P"
    gcloud projects create "$P" --organization="$ORG_ID"
  fi
  gcloud billing projects link "$P" --billing-account="$BILLING_ACCOUNT" >/dev/null
  gcloud services enable compute.googleapis.com logging.googleapis.com \
    monitoring.googleapis.com --project="$P"
done

# --- 2. Delete auto-created "default" networks --------------------------------
delete_default_network() {
  local P="$1"
  if gcloud compute networks describe default --project="$P" >/dev/null 2>&1; then
    log "Removing default network in $P"
    for RULE in $(gcloud compute firewall-rules list --project="$P" \
        --filter="network~/networks/default$" --format="value(name)"); do
      gcloud compute firewall-rules delete "$RULE" --project="$P" --quiet
    done
    gcloud compute networks delete default --project="$P" --quiet
  fi
}
for P in "$HOST_PROJECT" "${SERVICE_PROJECTS[@]}" "${TENANT_PROJECTS[@]}"; do
  delete_default_network "$P"
done

# --- 3. IAM for the Terraform service account ---------------------------------
log "Granting org-level roles to $SA_EMAIL"
for ROLE in roles/compute.xpnAdmin roles/browser; do
  gcloud organizations add-iam-policy-binding "$ORG_ID" \
    --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --condition=None >/dev/null
done

log "Granting Service Usage Consumer on the host project (quota project for API calls)"
gcloud projects add-iam-policy-binding "$HOST_PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/serviceusage.serviceUsageConsumer" --condition=None >/dev/null

log "Granting tenant project roles (used in Phase 4)"
for P in "${TENANT_PROJECTS[@]}"; do
  for ROLE in roles/compute.networkAdmin roles/compute.securityAdmin; do
    gcloud projects add-iam-policy-binding "$P" \
      --member="serviceAccount:${SA_EMAIL}" --role="$ROLE" --condition=None >/dev/null
  done
done

# --- 4. Terraform remote state bucket -----------------------------------------
gcloud services enable storage.googleapis.com --project="$HOST_PROJECT"
if ! gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  log "Creating state bucket gs://${STATE_BUCKET}"
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="$HOST_PROJECT" --location="$REGION" \
    --uniform-bucket-level-access --public-access-prevention
fi
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
gcloud storage buckets add-iam-policy-binding "gs://${STATE_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/storage.objectAdmin" >/dev/null

log "Done. Projects:"
gcloud projects list --filter="parent.id=${ORG_ID}" --format="table(projectId,projectNumber)"
