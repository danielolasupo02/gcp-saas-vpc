#!/usr/bin/env bash
# Phase 5 security tests
#
# Adds prod and dev test VMs (running as their environment service accounts)
# to the Phase 4 test VMs, then checks environment isolation, tenant isolation,
# org policy enforcement and private DNS.
#
# Usage:
#   ./scripts/05-security-test.sh up     # create all test VMs
#   ./scripts/05-security-test.sh test   # run the test matrix
#   ./scripts/05-security-test.sh down   # delete all test VMs
#   ./scripts/05-security-test.sh        # up + wait + test
set -euo pipefail

HOST_PROJECT="saas-vpc-host-2022"
PROD_PROJECT="saas-svc-prod-2022"
NONPROD_PROJECT="saas-svc-nonprod-2022"
FINTECH_PROJECT="saas-tenant-fintech-2022"
HEALTH_PROJECT="saas-tenant-health-2022"
REGION="us-central1"
ZONE="us-central1-a"
SUBNET_BASE="projects/${HOST_PROJECT}/regions/${REGION}/subnetworks"
HERE="$(cd "$(dirname "$0")" && pwd)"

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

create_env_vm() { # name project subnet sa
  if exists "$1" "$2"; then log "$1 exists"; return; fi
  log "Creating $1 in $3 (runs as $4)"
  gcloud compute instances create "$1" --project="$2" \
    --subnet="${SUBNET_BASE}/$3" \
    --service-account="$4" --scopes=logging-write,monitoring-write \
    "${COMMON_ARGS[@]}"
}

up() {
  bash "$HERE/04-connectivity-test.sh" up
  create_env_vm prod-test-vm "$PROD_PROJECT"    prod-subnet "sa-prod-app@${PROD_PROJECT}.iam.gserviceaccount.com"
  create_env_vm dev-test-vm  "$NONPROD_PROJECT" dev-subnet  "sa-dev-app@${NONPROD_PROJECT}.iam.gserviceaccount.com"
}

ip_of() {
  gcloud compute instances describe "$1" --project="$2" --zone="$ZONE" \
    --format='get(networkInterfaces[0].networkIP)'
}

run_on() { # vm project command
  gcloud compute ssh "$1" --project="$2" --zone="$ZONE" --tunnel-through-iap --quiet \
    --command="$3" 2>/dev/null | tail -n1 || true
}

probe() { # vm project ip port
  local out
  out=$(run_on "$1" "$2" "timeout 5 bash -c '</dev/tcp/$3/$4' 2>/dev/null && echo OPEN || echo BLOCKED")
  echo "${out:-ERROR}"
}

resolve() { # vm project hostname -> first IP
  local out
  out=$(run_on "$1" "$2" "getent hosts $3 | awk '{print \$1}' | head -n1")
  echo "${out:-NXDOMAIN}"
}

# Tries to create a VM WITH an external IP; the org policy should refuse it.
external_ip_check() {
  local out
  out=$(gcloud compute instances create ext-ip-policy-test --project="$PROD_PROJECT" \
          --zone="$ZONE" --machine-type=e2-micro --subnet="${SUBNET_BASE}/prod-subnet" \
          --image-family=debian-12 --image-project=debian-cloud \
          --no-service-account --no-scopes 2>&1 || true)
  if grep -q "vmExternalIpAccess" <<< "$out"; then
    echo BLOCKED
  else
    gcloud compute instances delete ext-ip-policy-test --project="$PROD_PROJECT" \
      --zone="$ZONE" --quiet >/dev/null 2>&1 || true
    echo ALLOWED
  fi
}

row() { # name expected actual why
  local result=FAIL
  [[ "$3" == "$2" || ( "$2" == "199.36.153.x" && "$3" == 199.36.153.* ) ]] && result=PASS
  [[ $result == PASS ]] && pass=$((pass+1)) || fail=$((fail+1))
  printf '%-34s %-13s %-13s %-6s %s\n' "$1" "$2" "$3" "$result" "$4"
}

test_matrix() {
  local SVC FIN HLT PRD DEV
  SVC=$(ip_of svc-test-vm "$HOST_PROJECT")
  FIN=$(ip_of fintech-test-vm "$FINTECH_PROJECT")
  HLT=$(ip_of health-test-vm "$HEALTH_PROJECT")
  PRD=$(ip_of prod-test-vm "$PROD_PROJECT")
  DEV=$(ip_of dev-test-vm "$NONPROD_PROJECT")
  log "IPs: svc=$SVC fintech=$FIN health=$HLT prod=$PRD dev=$DEV"

  pass=0; fail=0
  printf '\n%-34s %-13s %-13s %-6s %s\n' "TEST" "EXPECTED" "ACTUAL" "RESULT" "ENFORCED BY"
  printf '%.0s-' {1..110}; echo

  row "prod -> shared-svc :443"      OPEN    "$(probe prod-test-vm "$PROD_PROJECT" "$SVC" 443)"      "allow-envs-to-shared-svc"
  row "dev -> shared-svc :443"       OPEN    "$(probe dev-test-vm "$NONPROD_PROJECT" "$SVC" 443)"    "allow-envs-to-shared-svc"
  row "fintech -> shared-svc :443"   OPEN    "$(probe fintech-test-vm "$FINTECH_PROJECT" "$SVC" 443)" "allow-fintech-to-shared-svc"
  row "shared-svc -> fintech :443"   OPEN    "$(probe svc-test-vm "$HOST_PROJECT" "$FIN" 443)"       "allow-egress-shared-svc-to-tenants"
  row "dev -> prod :443"             BLOCKED "$(probe dev-test-vm "$NONPROD_PROJECT" "$PRD" 443)"    "deny-egress-private + deny-nonprod-to-prod"
  row "prod -> dev :443"             BLOCKED "$(probe prod-test-vm "$PROD_PROJECT" "$DEV" 443)"      "deny-egress-private-ranges"
  row "fintech -> prod :443"         BLOCKED "$(probe fintech-test-vm "$FINTECH_PROJECT" "$PRD" 443)" "tenant deny-egress-private + deny-tenants-to-envs"
  row "fintech -> health :443"       BLOCKED "$(probe fintech-test-vm "$FINTECH_PROJECT" "$HLT" 443)" "no route + org policy deny"
  row "prod -> shared-svc :22"       BLOCKED "$(probe prod-test-vm "$PROD_PROJECT" "$SVC" 22)"       "org policy: admin ports only from IAP"
  row "DNS storage.googleapis.com"   199.36.153.x "$(resolve fintech-test-vm "$FINTECH_PROJECT" storage.googleapis.com)" "private-googleapis zone"
  row "DNS api.saas.internal"        10.0.0.10 "$(resolve fintech-test-vm "$FINTECH_PROJECT" api.saas.internal)" "saas-internal zone"
  row "VM with external IP"          BLOCKED "$(external_ip_check)"                                  "org policy vmExternalIpAccess"

  printf '\n%d passed, %d failed\n' "$pass" "$fail"
}

down() {
  log "Deleting Phase 5 test VMs"
  exists prod-test-vm "$PROD_PROJECT"   && gcloud compute instances delete prod-test-vm --project="$PROD_PROJECT" --zone="$ZONE" --quiet
  exists dev-test-vm "$NONPROD_PROJECT" && gcloud compute instances delete dev-test-vm --project="$NONPROD_PROJECT" --zone="$ZONE" --quiet
  bash "$HERE/04-connectivity-test.sh" down
}

case "${1:-all}" in
  up)   up ;;
  test) test_matrix ;;
  down) down ;;
  all)  up; log "Waiting 90s for VMs and listeners to start"; sleep 90; test_matrix ;;
  *)    echo "Usage: $0 [up|test|down]"; exit 1 ;;
esac
