#!/usr/bin/env bash
# Network configuration backup (Phase 8)
#
# Exports every network object across the organization's network projects to a
# timestamped, checksummed archive and uploads it to a versioned bucket in the
# DR region. Backups are for audit and fast diagnosis ("what exactly changed or
# was deleted?"). Terraform + the versioned state bucket remain the way to rebuild.
#
# What is exported (YAML, one file per object type per project):
#   networks (incl. peerings), subnets, routes, firewall rules, Cloud Routers + NAT,
#   router BGP status, static addresses, HA VPN gateways/tunnels (no secrets),
#   DNS zones, record sets, DNS policies, Shared VPC attachments, log sinks and
#   log-based metrics, alert policies and dashboards, the org firewall policy
#   and org policies, plus Terraform state metadata (never the state itself:
#   it contains the VPN pre-shared key).
#
# Usage:
#   scripts/backup_config.sh backup            # export + upload, prints the backup ID
#   scripts/backup_config.sh list              # backups in the bucket
#   scripts/backup_config.sh verify <id>       # download and check every checksum
#   scripts/backup_config.sh diff <id> [<id2>|live]
#                                              # what changed between two backups,
#                                              # or between a backup and right now
set -uo pipefail

ORG_ID="172544480375"
HOST_PROJECT="saas-vpc-host-2022"
PROJECTS=(saas-vpc-host-2022 saas-svc-prod-2022 saas-svc-nonprod-2022 saas-tenant-fintech-2022 saas-tenant-health-2022)
NETWORK_PROJECTS=(saas-vpc-host-2022 saas-tenant-fintech-2022 saas-tenant-health-2022)
BUCKET="gs://${HOST_PROJECT}-network-config-backups"
PREFIX="network-config"
LOCAL_DIR="${BACKUP_DIR:-$HOME/backups}"
TF_DIR="${TF_DIR:-$HOME/terraform}"

# Fields that change on every read or update and would hide real changes in a diff.
VOLATILE='^\s*(creationTimestamp|fingerprint|etag|labelFingerprint|lastAttachTimestamp|lastDetachTimestamp|kind|selfLinkWithId|status|detailedStatus|uptime|uptimeSeconds|numLearnedRoutes|updateTime|createTime|mutationRecord):'

log() { printf '==> %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# run <outfile> <command...> : capture YAML, record failures instead of aborting
run() {
  local out="$1"; shift
  if ! "$@" --format=yaml > "$out" 2>>"$ERRLOG"; then
    echo "FAILED: $*" >> "$ERRLOG"
  fi
  [[ -s "$out" ]] || rm -f "$out"
}

api() { # out url : authenticated REST GET (for APIs gcloud doesn't cover in GA)
  curl -sf -H "Authorization: Bearer $(gcloud auth print-access-token)" "$2" > "$1" 2>>"$ERRLOG" \
    || { echo "FAILED: GET $2" >> "$ERRLOG"; rm -f "$1"; }
}

export_project() { # project dir
  local P="$1" D="$2/$1" R
  mkdir -p "$D"
  run "$D/networks.yaml"        gcloud compute networks list --project="$P"
  run "$D/subnets.yaml"         gcloud compute networks subnets list --project="$P"
  run "$D/routes.yaml"          gcloud compute routes list --project="$P"
  run "$D/firewall-rules.yaml"  gcloud compute firewall-rules list --project="$P"
  run "$D/addresses.yaml"       gcloud compute addresses list --project="$P"
  run "$D/vpn-gateways.yaml"    gcloud compute vpn-gateways list --project="$P"
  run "$D/vpn-tunnels.yaml"     gcloud compute vpn-tunnels list --project="$P"
  run "$D/dns-zones.yaml"       gcloud dns managed-zones list --project="$P"
  run "$D/dns-policies.yaml"    gcloud dns policies list --project="$P"
  run "$D/log-sinks.yaml"       gcloud logging sinks list --project="$P"
  run "$D/log-metrics.yaml"     gcloud logging metrics list --project="$P"

  # Cloud Routers: full config (BGP + NAT) and live BGP status
  for R in $(gcloud compute routers list --project="$P" --format='value(name,region.basename())' 2>>"$ERRLOG" | tr '\t' ':'); do
    run "$D/router-${R%%:*}.yaml"        gcloud compute routers describe "${R%%:*}" --region="${R##*:}" --project="$P"
    run "$D/router-${R%%:*}-status.yaml" gcloud compute routers get-status "${R%%:*}" --region="${R##*:}" --project="$P"
  done

  # DNS record sets per zone
  for Z in $(gcloud dns managed-zones list --project="$P" --format='value(name)' 2>>"$ERRLOG"); do
    run "$D/dns-records-${Z}.yaml" gcloud dns record-sets list --zone="$Z" --project="$P"
  done
}

snapshot() { # dir : full export into dir
  local DIR="$1" P
  mkdir -p "$DIR/org" "$DIR/terraform"
  ERRLOG="$DIR/errors.log"; : > "$ERRLOG"

  for P in "${PROJECTS[@]}"; do log "Exporting $P"; export_project "$P" "$DIR"; done

  log "Exporting Shared VPC, monitoring and org-level config"
  run "$DIR/org/shared-vpc-associations.yaml" gcloud compute shared-vpc associated-projects list "$HOST_PROJECT"
  api "$DIR/org/alert-policies.json" "https://monitoring.googleapis.com/v3/projects/${HOST_PROJECT}/alertPolicies"
  api "$DIR/org/notification-channels.json" "https://monitoring.googleapis.com/v3/projects/${HOST_PROJECT}/notificationChannels"
  api "$DIR/org/dashboards.json" "https://monitoring.googleapis.com/v1/projects/${HOST_PROJECT}/dashboards"
  run "$DIR/org/firewall-policies.yaml" gcloud compute firewall-policies list --organization="$ORG_ID"
  for FP in $(gcloud compute firewall-policies list --organization="$ORG_ID" --format='value(name)' 2>>"$ERRLOG"); do
    run "$DIR/org/firewall-policy-${FP}-rules.yaml" gcloud compute firewall-policies rules list --firewall-policy="$FP" --organization="$ORG_ID"
    run "$DIR/org/firewall-policy-${FP}-associations.yaml" gcloud compute firewall-policies associations list --firewall-policy="$FP" --organization="$ORG_ID"
  done
  run "$DIR/org/org-policies.yaml" gcloud org-policies list --organization="$ORG_ID"
  for C in $(gcloud org-policies list --organization="$ORG_ID" --format='value(constraint)' 2>>"$ERRLOG"); do
    run "$DIR/org/org-policy-${C##*/}.yaml" gcloud org-policies describe "$C" --organization="$ORG_ID"
  done

  # Terraform: resource inventory + state metadata only (state holds the VPN PSK).
  if command -v terraform >/dev/null && [[ -d "$TF_DIR/.terraform" ]]; then
    log "Recording Terraform state inventory"
    (cd "$TF_DIR" && terraform state list > "$DIR/terraform/resources.txt" 2>>"$ERRLOG")
    (cd "$TF_DIR" && terraform state pull 2>>"$ERRLOG" \
      | python3 -c 'import json,sys; s=json.load(sys.stdin); print(json.dumps({k:s.get(k) for k in ("version","terraform_version","serial","lineage")}, indent=2))' \
      > "$DIR/terraform/state-metadata.json")
  else
    echo "terraform not initialised in $TF_DIR; state inventory skipped" >> "$ERRLOG"
  fi

  # Never let a secret into a backup, even if an API starts returning one.
  grep -rlE 'sharedSecret:|privateKey|"password"' "$DIR" 2>/dev/null | grep -v errors.log \
    | while read -r f; do sed -i -E 's/(sharedSecret: ).*/\1REDACTED/' "$f"; done
}

cmd_backup() {
  local ID DIR
  ID="$(date -u +%Y%m%dT%H%M%SZ)"
  DIR="$LOCAL_DIR/$ID"
  log "Backup $ID -> $DIR"
  snapshot "$DIR"

  cat > "$DIR/metadata.json" <<EOF
{
  "backup_id": "$ID",
  "created_utc": "$(date -u +%FT%TZ)",
  "created_by": "$(gcloud config get-value account 2>/dev/null)",
  "impersonating": "$(gcloud config get-value auth/impersonate_service_account 2>/dev/null)",
  "git_commit": "$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || echo unknown)",
  "projects": "$(IFS=,; echo "${PROJECTS[*]}")",
  "files": $(find "$DIR" -type f -name '*.yaml' -o -type f -name '*.json' | wc -l),
  "export_errors": $(grep -c '^FAILED' "$DIR/errors.log" || true)
}
EOF
  (cd "$DIR" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256)

  tar -C "$LOCAL_DIR" -czf "$LOCAL_DIR/$ID.tar.gz" "$ID"
  sha256sum "$LOCAL_DIR/$ID.tar.gz" | awk '{print $1}' > "$LOCAL_DIR/$ID.tar.gz.sha256"
  gcloud storage cp "$LOCAL_DIR/$ID.tar.gz" "$LOCAL_DIR/$ID.tar.gz.sha256" "$BUCKET/$PREFIX/" --quiet \
    || die "upload to $BUCKET failed"

  log "Files: $(grep -o '"files": [0-9]*' "$DIR/metadata.json" | grep -o '[0-9]*')  Export errors: $(grep -c '^FAILED' "$DIR/errors.log" || true)"
  log "Uploaded $BUCKET/$PREFIX/$ID.tar.gz"
  echo "$ID"
}

cmd_list() {
  gcloud storage ls -l "$BUCKET/$PREFIX/*.tar.gz" 2>/dev/null | grep -v '^TOTAL' | sort -k2
}

fetch() { # id -> extracted dir path
  local ID="$1" T="$LOCAL_DIR/.restore"
  mkdir -p "$T"
  if [[ ! -d "$T/$ID" ]]; then
    gcloud storage cp "$BUCKET/$PREFIX/$ID.tar.gz" "$BUCKET/$PREFIX/$ID.tar.gz.sha256" "$T/" --quiet >/dev/null \
      || die "backup $ID not found in $BUCKET"
    [[ "$(sha256sum "$T/$ID.tar.gz" | awk '{print $1}')" == "$(cat "$T/$ID.tar.gz.sha256")" ]] \
      || die "archive checksum mismatch for $ID"
    tar -C "$T" -xzf "$T/$ID.tar.gz"
  fi
  echo "$T/$ID"
}

cmd_verify() {
  local ID="${1:?usage: verify <backup-id>}" DIR
  DIR="$(fetch "$ID")" || exit 1
  log "Verifying $ID"
  (cd "$DIR" && sha256sum --quiet -c MANIFEST.sha256) && log "OK: archive and all $(wc -l < "$DIR/MANIFEST.sha256") file checksums match"
}

normalise() { # dir -> copy with volatile fields stripped, for diffing
  local SRC="$1" OUT="$2"
  rm -rf "$OUT"; cp -r "$SRC" "$OUT"
  rm -f "$OUT/MANIFEST.sha256" "$OUT/metadata.json" "$OUT/errors.log" "$OUT"/*/*-status.yaml
  find "$OUT" -type f -name '*.yaml' -exec sed -i -E "/$VOLATILE/d" {} +
}

cmd_diff() {
  local A="${1:?usage: diff <id> [<id2>|live]}" B="${2:-live}" DA DB
  DA="$(fetch "$A")" || exit 1
  if [[ "$B" == live ]]; then
    DB="$LOCAL_DIR/.restore/live-$(date -u +%H%M%S)"
    log "Taking a live snapshot to compare against"
    snapshot "$DB" >/dev/null
  else
    DB="$(fetch "$B")" || exit 1
  fi
  normalise "$DA" "$LOCAL_DIR/.restore/a"
  normalise "$DB" "$LOCAL_DIR/.restore/b"
  log "Changes from $A to $B (- only in $A, + only in $B):"
  if diff -ru "$LOCAL_DIR/.restore/a" "$LOCAL_DIR/.restore/b" | sed "s#$LOCAL_DIR/.restore/[ab]/##g"; then
    log "No configuration differences"
  fi
}

command -v gcloud >/dev/null || die "gcloud not found"
mkdir -p "$LOCAL_DIR"

case "${1:-}" in
  backup) cmd_backup ;;
  list)   cmd_list ;;
  verify) shift; cmd_verify "$@" ;;
  diff)   shift; cmd_diff "$@" ;;
  *)      sed -n '2,26p' "$0"; exit 1 ;;
esac
