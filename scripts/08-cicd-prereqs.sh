#!/usr/bin/env bash
# Phase 8 prerequisites: keyless CI/CD for GitHub Actions (run as your own user)
#
#   GitHub Actions OIDC token
#     -> Workload Identity Federation (pool "github", provider "github-oidc")
#        only tokens from danielolasupo02/gcp-saas-vpc are accepted
#     -> github-ci-sa                       (no keys; key creation is blocked by org policy)
#     -> impersonates network-admin-sa      (same path a human admin uses)
#
# Kept out of Terraform on purpose (Phase 5 decision): the Terraform identity
# never grants itself or anyone else access.
# Safe to re-run.
set -euo pipefail

HOST_PROJECT="saas-vpc-host-2022"
GITHUB_REPO="danielolasupo02/gcp-saas-vpc"
POOL="github"
PROVIDER="github-oidc"
CI_SA_NAME="github-ci-sa"
CI_SA="${CI_SA_NAME}@${HOST_PROJECT}.iam.gserviceaccount.com"
TF_SA="network-admin-sa@${HOST_PROJECT}.iam.gserviceaccount.com"

log() { printf '\n==> %s\n' "$*"; }

PROJECT_NUMBER=$(gcloud projects describe "$HOST_PROJECT" --format='value(projectNumber)')

log "Enabling APIs"
gcloud services enable iam.googleapis.com iamcredentials.googleapis.com sts.googleapis.com \
  --project="$HOST_PROJECT"

log "Workload identity pool + GitHub OIDC provider"
gcloud iam workload-identity-pools describe "$POOL" --project="$HOST_PROJECT" --location=global >/dev/null 2>&1 \
  || gcloud iam workload-identity-pools create "$POOL" --project="$HOST_PROJECT" --location=global \
       --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers describe "$PROVIDER" --project="$HOST_PROJECT" \
  --location=global --workload-identity-pool="$POOL" >/dev/null 2>&1 \
  || gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" --project="$HOST_PROJECT" \
       --location=global --workload-identity-pool="$POOL" \
       --display-name="GitHub OIDC" \
       --issuer-uri="https://token.actions.githubusercontent.com" \
       --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.event_name=assertion.event_name" \
       --attribute-condition="assertion.repository == '${GITHUB_REPO}'"

log "CI service account"
gcloud iam service-accounts describe "$CI_SA" --project="$HOST_PROJECT" >/dev/null 2>&1 \
  || gcloud iam service-accounts create "$CI_SA_NAME" --project="$HOST_PROJECT" \
       --display-name="GitHub Actions CI (keyless, via WIF)"

log "Only workflows in ${GITHUB_REPO} may act as ${CI_SA_NAME}"
gcloud iam service-accounts add-iam-policy-binding "$CI_SA" --project="$HOST_PROJECT" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${GITHUB_REPO}" \
  --condition=None >/dev/null

log "${CI_SA_NAME} may impersonate the Terraform SA (exactly like an admin)"
gcloud iam service-accounts add-iam-policy-binding "$TF_SA" --project="$HOST_PROJECT" \
  --role="roles/iam.serviceAccountTokenCreator" --member="serviceAccount:${CI_SA}" \
  --condition=None >/dev/null
gcloud projects add-iam-policy-binding "$HOST_PROJECT" \
  --role="roles/serviceusage.serviceUsageConsumer" --member="serviceAccount:${CI_SA}" \
  --condition=None >/dev/null

log "Done. Add these to GitHub: Settings > Secrets and variables > Actions"
cat <<EOF

  Variables:
    GCP_WIF_PROVIDER = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}
    GCP_CI_SA        = ${CI_SA}
  Secret:
    ALERT_EMAIL      = <the address in your terraform.tfvars>

  Environment (Settings > Environments > New):
    production       -> Required reviewers: you
EOF
