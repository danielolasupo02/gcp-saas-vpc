#!/usr/bin/env bash
# Phase 8 disaster-recovery tests
#
#   up     create standby VMs in the DR region (us-east1)
#   test   DR readiness matrix: the DR region works with no config changes
#   drill  accidental-deletion drill: delete a firewall rule, see the impact,
#          find it with the config backup, restore with Terraform, measure RTO
#   down   delete the DR test VMs
#
# Needs: terraform initialised in ~/terraform (drill only) and the backup bucket.
set -euo pipefail

HOST_PROJECT="saas-vpc-host-2022"
PROD_PROJECT="saas-svc-prod-2022"
FINTECH_PROJECT="saas-tenant-fintech-2022"
DR_REGION="us-east1"
ZONE="us-east1-b"
TF_DIR="$HOME/terraform"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUBNET_BASE="projects/${HOST_PROJECT}/regions/${DR_REGION}/subnetworks"

log() { printf '\n==> %s\n' "$*"; }
exists() { gcloud compute instances describe "$1" --project="$2" --zone="$ZONE" >/dev/null 2>&1; }

STARTUP_FILE="$(mktemp)"; trap 'rm -f "$STARTUP_FILE"' EXIT
cat > "$STARTUP_FILE" <<'EOF'
#!/bin/bash
systemd-run --unit=test-listener python3 -m http.server 443
EOF
COMMON=(--zone="$ZONE" --machine-type=e2-micro --no-address --image-family=debian-12
  --image-project=debian-cloud --shielded-secure-boot --metadata-from-file=startup-script="$STARTUP_FILE")

create() { # name project subnet [sa]
  if exists "$1" "$2"; then log "$1 exists"; return; fi
  log "Creating $1 in $3"
  if [[ -n "${4:-}" ]]; then
    gcloud compute instances create "$1" --project="$2" --subnet="$3" \
      --service-account="$4" --scopes=logging-write,monitoring-write "${COMMON[@]}"
  else
    gcloud compute instances create "$1" --project="$2" --subnet="$3" \
      --no-service-account --no-scopes "${COMMON[@]}"
  fi
}

up() {
  create svc-east-vm     "$HOST_PROJECT"    "${SUBNET_BASE}/shared-svc-subnet-east" "sa-shared-svc@${HOST_PROJECT}.iam.gserviceaccount.com"
  create prod-east-vm    "$PROD_PROJECT"    "${SUBNET_BASE}/prod-subnet-east"       "sa-prod-app@${PROD_PROJECT}.iam.gserviceaccount.com"
  create fintech-east-vm "$FINTECH_PROJECT" "fintech-subnet-east"
}

ip_of() { gcloud compute instances describe "$1" --project="$2" --zone="$ZONE" --format='get(networkInterfaces[0].networkIP)'; }
run_on() {
  gcloud compute ssh "$1" --project="$2" --zone="$ZONE" --tunnel-through-iap --quiet \
    --command="$3" 2>/dev/null | tail -n1 || true
}
probe() { local o; o=$(run_on "$1" "$2" "timeout 5 bash -c '</dev/tcp/$3/$4' 2>/dev/null && echo OPEN || echo BLOCKED"); echo "${o:-ERROR}"; }
egress_ip() { local o; o=$(run_on "$1" "$2" "curl -s -m 10 https://api.ipify.org"); echo "${o:-NONE}"; }
nat_ip() { gcloud compute addresses list --project="$1" --filter="name=$2" --format='value(address)'; }

row() {
  printf '%-40s %-22s %-22s %s\n' "$1" "$2" "$3" "$4"
  [[ "$4" == PASS ]] && pass=$((pass+1)) || fail=$((fail+1))
}
is() { [[ "$1" == "$2" ]] && echo PASS || echo FAIL; }

test_matrix() {
  local SVC FIN PRD EAST_NAT FIN_NAT FIN_EXPECT DR_SUBNETS LATEST VERIFY P
  SVC=$(ip_of svc-east-vm "$HOST_PROJECT")
  FIN=$(ip_of fintech-east-vm "$FINTECH_PROJECT")
  PRD=$(ip_of prod-east-vm "$PROD_PROJECT")
  EAST_NAT=$(nat_ip "$HOST_PROJECT" nat-shared-east-prod-ip-0)
  FIN_NAT=$(nat_ip "$FINTECH_PROJECT" nat-fintech-east-ip-0)
  FIN_EXPECT=${FIN_NAT:-NONE}

  DR_SUBNETS=0
  for P in "$HOST_PROJECT" "$FINTECH_PROJECT" saas-tenant-health-2022; do
    DR_SUBNETS=$((DR_SUBNETS + $(gcloud compute networks subnets list --project="$P" \
      --filter="region:$DR_REGION" --format='value(name)' | wc -l)))
  done

  LATEST=$(gcloud storage ls "gs://${HOST_PROJECT}-network-config-backups/network-config/*.tar.gz" 2>/dev/null \
    | sort | tail -n1 | xargs -r basename | sed 's/.tar.gz$//')
  VERIFY=FAIL
  [[ -n "$LATEST" ]] && bash "$HERE/backup_config.sh" verify "$LATEST" >/dev/null 2>&1 && VERIFY=PASS

  log "DR VMs: svc-east=$SVC prod-east=$PRD fintech-east=$FIN | east NAT=$EAST_NAT"
  pass=0; fail=0
  printf '\n%-40s %-22s %-22s %s\n' TEST EXPECTED ACTUAL RESULT; printf '%.0s-' {1..95}; echo
  local R
  row "DR subnets in $DR_REGION"            "4"            "$DR_SUBNETS" "$(is "$DR_SUBNETS" 4)"
  R=$(egress_ip prod-east-vm "$PROD_PROJECT")
  row "prod-east egress IP (east NAT)"      "$EAST_NAT"    "$R"   "$(is "$R" "$EAST_NAT")"
  R=$(probe prod-east-vm "$PROD_PROJECT" "$SVC" 443)
  row "prod-east -> shared-svc-east :443"   OPEN           "$R"   "$(is "$R" OPEN)"
  R=$(probe fintech-east-vm "$FINTECH_PROJECT" "$SVC" 443)
  row "fintech-east -> shared-svc-east :443" OPEN          "$R"   "$(is "$R" OPEN)"
  R=$(probe svc-east-vm "$HOST_PROJECT" "$FIN" 443)
  row "shared-svc-east -> fintech-east :443" OPEN          "$R"   "$(is "$R" OPEN)"
  R=$(probe fintech-east-vm "$FINTECH_PROJECT" "$PRD" 443)
  row "fintech-east -> prod-east :443"      BLOCKED        "$R"   "$(is "$R" BLOCKED)"
  R=$(egress_ip fintech-east-vm "$FINTECH_PROJECT")
  row "fintech-east internet (DR NAT)"      "$FIN_EXPECT"  "$R"   "$(is "$R" "$FIN_EXPECT")"
  row "latest config backup verifies"       "${LATEST:-none}" "$VERIFY" "$VERIFY"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  [[ -z "$FIN_NAT" ]] && echo "(fintech-east has no internet: pilot light. Set enable_dr_egress = true during a failover.)"
  return 0
}

drill() {
  local RULE=allow-shared-svc-callbacks
  local TARGET='google_compute_firewall.tenant_allow_shared_svc_callbacks["fintech"]'
  local SVC FIN ID T0 T1 R
  SVC=$(ip_of svc-east-vm "$HOST_PROJECT"); FIN=$(ip_of fintech-east-vm "$FINTECH_PROJECT")

  log "1/6 Backup before the incident"
  ID=$(bash "$HERE/backup_config.sh" backup)

  log "2/6 Baseline: shared-svc-east -> fintech-east :443"
  echo "    $(probe svc-east-vm "$HOST_PROJECT" "$FIN" 443)"

  log "3/6 INCIDENT: deleting $RULE in $FINTECH_PROJECT"
  T0=$(date +%s)
  gcloud compute firewall-rules delete "$RULE" --project="$FINTECH_PROJECT" --quiet

  log "4/6 Impact"
  sleep 15
  echo "    shared-svc-east -> fintech-east :443 = $(probe svc-east-vm "$HOST_PROJECT" "$FIN" 443)"

  log "5/6 Diagnose: compare backup $ID with live config"
  bash "$HERE/backup_config.sh" diff "$ID" live 2>/dev/null | grep -E "^[-+]- name|^diff|^[-+]  name" | head -20 || true

  log "6/6 Recover with Terraform"
  (cd "$TF_DIR" && terraform plan -no-color -parallelism=1 -target="$TARGET" | grep -E "will be created|^Plan:" || true)
  (cd "$TF_DIR" && terraform apply -no-color -parallelism=1 -auto-approve -target="$TARGET" | tail -n 2 || true)
  sleep 15
  R=$(probe svc-east-vm "$HOST_PROJECT" "$FIN" 443)
  T1=$(date +%s)

  printf '\n%-28s %s\n%-28s %s\n%-28s %ss\n' \
    "After restore:" "shared-svc-east -> fintech-east :443 = $R" \
    "Backup used for diagnosis:" "$ID" \
    "Recovery time (RTO):" "$((T1 - T0))"
  [[ "$R" == OPEN ]] && echo "RESULT: PASS" || echo "RESULT: FAIL"
  echo "Run 'terraform plan' (no -target) to confirm there is no other drift."
}

down() {
  local V
  for V in "svc-east-vm $HOST_PROJECT" "prod-east-vm $PROD_PROJECT" "fintech-east-vm $FINTECH_PROJECT"; do
    set -- $V
    exists "$1" "$2" && gcloud compute instances delete "$1" --project="$2" --zone="$ZONE" --quiet
  done
  return 0
}

case "${1:-}" in
  up)    up ;;
  test)  test_matrix ;;
  drill) drill ;;
  down)  down ;;
  *)     echo "Usage: $0 [up|test|drill|down]"; exit 1 ;;
esac
