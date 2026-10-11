#!/usr/bin/env bash
# Phase 4 connectivity and isolation tests
#
# Creates three small test VMs (no external IPs), then probes TCP ports between
# them over IAP SSH and compares each result with the expected outcome.
#
#   svc-test-vm      shared-svc-subnet  (shared VPC, runs as sa-shared-svc)
#   fintech-test-vm  fintech-subnet     (customer-fintech-vpc)
#   health-test-vm   health-subnet      (customer-health-vpc)
#
# Usage:
#   ./scripts/04-connectivity-test.sh up     # create VMs
#   ./scripts/04-connectivity-test.sh test   # run the test matrix
#   ./scripts/04-connectivity-test.sh down   # delete VMs (stop paying)
#   ./scripts/04-connectivity-test.sh        # up + wait + test
set -euo pipefail

HOST_PROJECT="saas-vpc-host-2022"
FINTECH_PROJECT="saas-tenant-fintech-2022"
HEALTH_PROJECT="saas-tenant-health-2022"
ZONE="us-central1-a"
SVC_SA="sa-shared-svc@${HOST_PROJECT}.iam.gserviceaccount.com"

# Every VM listens on tcp:443 so there is something to connect to.
STARTUP_FILE="$(mktemp)"
trap 'rm -f "$STARTUP_FILE"' EXIT
cat > "$STARTUP_FILE" <<'EOF'
#!/bin/bash
systemd-run --unit=test-listener python3 -m http.server 443
EOF

COMMON_ARGS=(--zone="$ZONE" --machine-type=e2-micro --no-address
  --image-family=debian-12 --image-project=debian-cloud
  --shielded-secure-boot --metadata-from-file=startup-script="$STARTUP_FILE")

log() { printf '\n==> %s\n' "$*"; }

exists() { gcloud compute instances describe "$1" --project="$2" --zone="$ZONE" >/dev/null 2>&1; }

up() {
  if exists svc-test-vm "$HOST_PROJECT"; then log "svc-test-vm exists"; else
    log "Creating svc-test-vm (shared VPC)"
    gcloud compute instances create svc-test-vm --project="$HOST_PROJECT" \
      --network=shared-vpc-network --subnet=shared-svc-subnet \
      --service-account="$SVC_SA" --scopes=logging-write,monitoring-write \
      "${COMMON_ARGS[@]}"
  fi
  for T in fintech health; do
    P_VAR="${T^^}_PROJECT"; P="${!P_VAR}"
    if exists "${T}-test-vm" "$P"; then log "${T}-test-vm exists"; else
      log "Creating ${T}-test-vm (customer-${T}-vpc)"
      gcloud compute instances create "${T}-test-vm" --project="$P" \
        --network="customer-${T}-vpc" --subnet="${T}-subnet" \
        --no-service-account --no-scopes \
        "${COMMON_ARGS[@]}"
    fi
  done
}

ip_of() {
  gcloud compute instances describe "$1" --project="$2" --zone="$ZONE" \
    --format='get(networkInterfaces[0].networkIP)'
}

# probe FROM_VM FROM_PROJECT DEST_IP PORT -> prints OPEN / BLOCKED / ERROR
probe() {
  local out
  out=$(gcloud compute ssh "$1" --project="$2" --zone="$ZONE" \
          --tunnel-through-iap --quiet \
          --command="timeout 5 bash -c '</dev/tcp/$3/$4' 2>/dev/null && echo OPEN || echo BLOCKED" \
          2>/dev/null | tail -n1 || true)
  echo "${out:-ERROR}"
}

test_matrix() {
  local SVC_IP FIN_IP HLT_IP
  SVC_IP=$(ip_of svc-test-vm "$HOST_PROJECT")
  FIN_IP=$(ip_of fintech-test-vm "$FINTECH_PROJECT")
  HLT_IP=$(ip_of health-test-vm "$HEALTH_PROJECT")
  log "IPs: svc=$SVC_IP  fintech=$FIN_IP  health=$HLT_IP"

  # name | from vm | from project | dest ip | port | expected | why
  local TESTS=(
    "fintech -> shared-svc :443|fintech-test-vm|$FINTECH_PROJECT|$SVC_IP|443|OPEN|peering + allow-fintech-to-shared-svc"
    "health  -> shared-svc :443|health-test-vm|$HEALTH_PROJECT|$SVC_IP|443|OPEN|peering + allow-health-to-shared-svc"
    "shared-svc -> fintech :443|svc-test-vm|$HOST_PROJECT|$FIN_IP|443|OPEN|allow-shared-svc-callbacks"
    "shared-svc -> health  :443|svc-test-vm|$HOST_PROJECT|$HLT_IP|443|OPEN|allow-shared-svc-callbacks"
    "fintech -> health     :443|fintech-test-vm|$FINTECH_PROJECT|$HLT_IP|443|BLOCKED|no route: peering is non-transitive"
    "health  -> fintech    :443|health-test-vm|$HEALTH_PROJECT|$FIN_IP|443|BLOCKED|no route: peering is non-transitive"
    "fintech -> shared-svc :22 |fintech-test-vm|$FINTECH_PROJECT|$SVC_IP|22|BLOCKED|only tcp:443 allowed from tenants"
  )

  local pass=0 fail=0
  printf '\n%-28s %-9s %-9s %-6s %s\n' "TEST" "EXPECTED" "ACTUAL" "RESULT" "REASON"
  printf '%.0s-' {1..100}; echo
  for t in "${TESTS[@]}"; do
    IFS='|' read -r name vm proj ip port expected why <<< "$t"
    actual=$(probe "$vm" "$proj" "$ip" "$port")
    if [[ "$actual" == "$expected" ]]; then result=PASS; pass=$((pass+1)); else result=FAIL; fail=$((fail+1)); fi
    printf '%-28s %-9s %-9s %-6s %s\n' "$name" "$expected" "$actual" "$result" "$why"
  done
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
}

down() {
  log "Deleting test VMs"
  exists svc-test-vm "$HOST_PROJECT" && gcloud compute instances delete svc-test-vm --project="$HOST_PROJECT" --zone="$ZONE" --quiet
  exists fintech-test-vm "$FINTECH_PROJECT" && gcloud compute instances delete fintech-test-vm --project="$FINTECH_PROJECT" --zone="$ZONE" --quiet
  exists health-test-vm "$HEALTH_PROJECT" && gcloud compute instances delete health-test-vm --project="$HEALTH_PROJECT" --zone="$ZONE" --quiet
  log "Done"
}

case "${1:-all}" in
  up)   up ;;
  test) test_matrix ;;
  down) down ;;
  all)  up; log "Waiting 90s for VMs and listeners to start"; sleep 90; test_matrix ;;
  *)    echo "Usage: $0 [up|test|down]"; exit 1 ;;
esac
