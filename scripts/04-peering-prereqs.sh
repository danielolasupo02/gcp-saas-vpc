#!/usr/bin/env bash
# Phase 4 prerequisites (run as your own user before terraform apply)
#  - Creates the sa-shared-svc service account that firewall rules target
#  - Enables the IAP API in the tenant projects (needed for IAP SSH to test VMs)
# Safe to re-run.
set -euo pipefail

HOST_PROJECT="saas-vpc-host-2022"
TENANT_PROJECTS=(saas-tenant-fintech-2022 saas-tenant-health-2022)
SVC_SA="sa-shared-svc@${HOST_PROJECT}.iam.gserviceaccount.com"

log() { printf '\n==> %s\n' "$*"; }

if gcloud iam service-accounts describe "$SVC_SA" --project="$HOST_PROJECT" >/dev/null 2>&1; then
  log "Service account $SVC_SA already exists"
else
  log "Creating $SVC_SA"
  gcloud iam service-accounts create sa-shared-svc \
    --project="$HOST_PROJECT" \
    --display-name="Shared services workloads (firewall target)"
fi

for P in "${TENANT_PROJECTS[@]}"; do
  log "Enabling IAP API in $P"
  gcloud services enable iap.googleapis.com --project="$P"
done

log "Done"
gcloud iam service-accounts list --project="$HOST_PROJECT" --format="table(email,displayName)"
