#!/usr/bin/env bash
# Phase 7 prerequisites (run as your own user before terraform apply)
#  - Enables BigQuery, Logging and Network Management (Connectivity Tests) APIs
#  - Lets the Terraform SA create sinks, log-based metrics and the log destinations
#  - Lets YOU run Connectivity Tests and query the flow-log dataset
# Safe to re-run.
set -euo pipefail

HOST_PROJECT="saas-vpc-host-2022"
LOG_PROJECTS=(saas-vpc-host-2022 saas-tenant-fintech-2022 saas-tenant-health-2022)
TF_SA="network-admin-sa@${HOST_PROJECT}.iam.gserviceaccount.com"
ADMIN="user:$(gcloud config get-value account 2>/dev/null)"

log() { printf '\n==> %s\n' "$*"; }
grant() { # project member role
  gcloud projects add-iam-policy-binding "$1" --member="$2" --role="$3" --condition=None >/dev/null
}

log "Enabling APIs"
gcloud services enable bigquery.googleapis.com logging.googleapis.com \
  networkmanagement.googleapis.com --project="$HOST_PROJECT"
for P in "${LOG_PROJECTS[@]}"; do
  gcloud services enable logging.googleapis.com --project="$P"
done

log "Terraform SA: sinks + log-based metrics in every network project"
for P in "${LOG_PROJECTS[@]}"; do
  grant "$P" "serviceAccount:${TF_SA}" roles/logging.admin
done

log "Terraform SA: archive bucket + BigQuery dataset (and their IAM) in the host"
grant "$HOST_PROJECT" "serviceAccount:${TF_SA}" roles/storage.admin
grant "$HOST_PROJECT" "serviceAccount:${TF_SA}" roles/bigquery.admin

log "You: Connectivity Tests + query flow logs in BigQuery"
grant "$HOST_PROJECT" "$ADMIN" roles/networkmanagement.admin
grant "$HOST_PROJECT" "$ADMIN" roles/bigquery.user
grant "$HOST_PROJECT" "$ADMIN" roles/bigquery.dataViewer

log "Done"
