#!/usr/bin/env bash
# Phase 5 prerequisites (run as your own user, the org admin, before terraform apply)
#  - Creates per-environment workload service accounts (firewall targets)
#  - Enables the APIs Phase 5 uses
#  - Grants the Terraform service account the org/project roles it needs
#  - Grants YOU admin access through IAP + OS Login (kept out of Terraform so the
#    Terraform identity never needs permission to edit IAM policies)
# Safe to re-run.
set -euo pipefail

ORG_ID="172544480375"
HOST_PROJECT="saas-vpc-host-2022"
PROD_PROJECT="saas-svc-prod-2022"
NONPROD_PROJECT="saas-svc-nonprod-2022"
TENANT_PROJECTS=(saas-tenant-fintech-2022 saas-tenant-health-2022)
TF_SA="network-admin-sa@${HOST_PROJECT}.iam.gserviceaccount.com"
ADMIN="user:$(gcloud config get-value account 2>/dev/null)"

log() { printf '\n==> %s\n' "$*"; }

create_sa() { # name project display
  if gcloud iam service-accounts describe "$1@$2.iam.gserviceaccount.com" --project="$2" >/dev/null 2>&1; then
    log "$1 already exists in $2"
  else
    log "Creating $1 in $2"
    gcloud iam service-accounts create "$1" --project="$2" --display-name="$3"
  fi
}

# --- 1. Workload identities --------------------------------------------------
create_sa sa-prod-app    "$PROD_PROJECT"    "Production workloads (firewall target)"
create_sa sa-staging-app "$NONPROD_PROJECT" "Staging workloads (firewall target)"
create_sa sa-dev-app     "$NONPROD_PROJECT" "Dev workloads (firewall target)"

# --- 2. APIs -----------------------------------------------------------------
log "Enabling APIs"
gcloud services enable orgpolicy.googleapis.com securitycenter.googleapis.com \
  dns.googleapis.com --project="$HOST_PROJECT"
for P in "${TENANT_PROJECTS[@]}"; do
  gcloud services enable dns.googleapis.com --project="$P"
done
for P in "$PROD_PROJECT" "$NONPROD_PROJECT"; do
  gcloud services enable iap.googleapis.com --project="$P"
done

# --- 3. Terraform service account ---------------------------------------------
log "Granting org-level roles to $TF_SA"
for ROLE in roles/compute.orgFirewallPolicyAdmin \
            roles/compute.orgSecurityResourceAdmin \
            roles/orgpolicy.policyAdmin; do
  gcloud organizations add-iam-policy-binding "$ORG_ID" \
    --member="serviceAccount:${TF_SA}" --role="$ROLE" --condition=None >/dev/null
done

log "Granting DNS admin to $TF_SA (host + tenants, for cross-project zone binding)"
for P in "$HOST_PROJECT" "${TENANT_PROJECTS[@]}"; do
  gcloud projects add-iam-policy-binding "$P" \
    --member="serviceAccount:${TF_SA}" --role="roles/dns.admin" --condition=None >/dev/null
done

# --- 4. Admin access via IAP + OS Login ----------------------------------------
log "Granting $ADMIN IAP tunnel + OS Login admin on every project with VMs"
for P in "$HOST_PROJECT" "$PROD_PROJECT" "$NONPROD_PROJECT" "${TENANT_PROJECTS[@]}"; do
  for ROLE in roles/iap.tunnelResourceAccessor roles/compute.osAdminLogin; do
    gcloud projects add-iam-policy-binding "$P" \
      --member="$ADMIN" --role="$ROLE" --condition=None >/dev/null
  done
done
# Needed when the admin's account is outside the org's domain (e.g. a gmail account)
gcloud organizations add-iam-policy-binding "$ORG_ID" \
  --member="$ADMIN" --role="roles/compute.osLoginExternalUser" --condition=None >/dev/null

log "Done"
