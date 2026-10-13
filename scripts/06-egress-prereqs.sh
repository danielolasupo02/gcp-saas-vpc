#!/usr/bin/env bash
# Phase 6 prerequisites (run as your own user before terraform apply)
#  - Lets the Terraform SA build a central metrics scope and NAT/VPN dashboard
# Safe to re-run.
set -euo pipefail

HOST_PROJECT="saas-vpc-host-2022"
PROJECTS=(saas-vpc-host-2022 saas-svc-prod-2022 saas-svc-nonprod-2022 saas-tenant-fintech-2022 saas-tenant-health-2022)
TF_SA="network-admin-sa@${HOST_PROJECT}.iam.gserviceaccount.com"

log() { printf '\n==> %s\n' "$*"; }

log "Enabling Monitoring API everywhere"
for P in "${PROJECTS[@]}"; do
  gcloud services enable monitoring.googleapis.com --project="$P"
done

log "Granting monitoring.admin to $TF_SA (dashboards + metrics scope)"
for P in "${PROJECTS[@]}"; do
  gcloud projects add-iam-policy-binding "$P" \
    --member="serviceAccount:${TF_SA}" --role="roles/monitoring.admin" --condition=None >/dev/null
done

log "Done"
