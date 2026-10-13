#!/usr/bin/env bash
# Phase 6 egress + hybrid tests
#
# Reuses the Phase 5 test VMs and adds an on-prem VM, then checks:
#   - each environment/tenant leaves the internet through ITS OWN static NAT IP
#   - only HTTPS egress is allowed
#   - on-prem reaches shared services over HA VPN + BGP, and nothing else
#
# Usage:
#   ./scripts/06-egress-test.sh up        # create all test VMs
#   ./scripts/06-egress-test.sh test      # run the test matrix
#   ./scripts/06-egress-test.sh failover  # drain the active prod NAT IP, prove egress moves
#   ./scripts/06-egress-test.sh down      # delete all test VMs
#   ./scripts/06-egress-test.sh           # up + wait + test
set -euo pipefail

HOST_PROJECT="saas-vpc-host-2022"
PROD_PROJECT="saas-svc-prod-2022"
NONPROD_PROJECT="saas-svc-nonprod-2022"
FINTECH_PROJECT="saas-tenant-fintech-2022"
HEALTH_PROJECT="saas-tenant-health-2022"
REGION="us-central1"
ZONE="us-central1-a"
BGP_ROUTER="bgp-router-${REGION}"
HERE="$(cd "$(dirname "$0")" && pwd)"

log() { printf '\n==> %s\n' "$*"; }
exists() { gcloud compute instances describe "$1" --project="$2" --zone="$ZONE" >/dev/null 2>&1; }

up() {
  bash "$HERE/05-security-test.sh" up
  if exists onprem-test-vm "$HOST_PROJECT"; then log "onprem-test-vm exists"; else
    log "Creating onprem-test-vm (onprem-sim-vpc)"
    gcloud compute instances create onprem-test-vm --project="$HOST_PROJECT" --zone="$ZONE" \
      --machine-type=e2-micro --no-address --network=onprem-sim-vpc --subnet=onprem-subnet \
      --no-service-account --no-scopes --image-family=debian-12 --image-project=debian-cloud \
      --shielded-secure-boot
  fi
}

ip_of() {
  gcloud compute instances describe "$1" --project="$2" --zone="$ZONE" \
    --format='get(networkInterfaces[0].networkIP)'
}

run_on() { # vm project command
  gcloud compute ssh "$1" --project="$2" --zone="$ZONE" --tunnel-through-iap --quiet \
    --command="$3" 2>/dev/null | tail -n1 || true
}

egress_ip() { # vm project -> public IP the internet sees
  local out
  out=$(run_on "$1" "$2" "curl -s -m 10 https://api.ipify.org")
  echo "${out:-NONE}"
}

probe() { # vm project ip port
  local out
  out=$(run_on "$1" "$2" "timeout 5 bash -c '</dev/tcp/$3/$4' 2>/dev/null && echo OPEN || echo BLOCKED")
  echo "${out:-ERROR}"
}

nat_ips() { # project gateway-name -> space separated IPs
  gcloud compute addresses list --project="$1" --filter="name~^nat-$2-ip-" \
    --format="value(address)" | tr '\n' ' ' | sed 's/ $//'
}

row() { # name expected actual result why
  printf '%-36s %-26s %-26s %-6s %s\n' "$1" "$2" "$3" "$4" "$5"
  [[ "$4" == PASS ]] && pass=$((pass+1)) || fail=$((fail+1))
}

check_in() { # actual "list" -> PASS/FAIL
  [[ -n "$1" && " $2 " == *" $1 "* ]] && echo PASS || echo FAIL
}

test_matrix() {
  local PROD_NAT NONPROD_NAT FIN_NAT HLT_NAT SVC PRD
  PROD_NAT=$(nat_ips "$HOST_PROJECT" shared-central-prod)
  NONPROD_NAT=$(nat_ips "$HOST_PROJECT" shared-central-nonprod)
  FIN_NAT=$(nat_ips "$FINTECH_PROJECT" fintech)
  HLT_NAT=$(nat_ips "$HEALTH_PROJECT" health)
  SVC=$(ip_of svc-test-vm "$HOST_PROJECT")
  PRD=$(ip_of prod-test-vm "$PROD_PROJECT")
  log "NAT IPs: prod=[$PROD_NAT] nonprod=[$NONPROD_NAT] fintech=[$FIN_NAT] health=[$HLT_NAT]"

  local E_PROD E_DEV E_FIN E_HLT BGP_UP LEARNED
  E_PROD=$(egress_ip prod-test-vm "$PROD_PROJECT")
  E_DEV=$(egress_ip dev-test-vm "$NONPROD_PROJECT")
  E_FIN=$(egress_ip fintech-test-vm "$FINTECH_PROJECT")
  E_HLT=$(egress_ip health-test-vm "$HEALTH_PROJECT")
  BGP_UP=$(gcloud compute routers get-status "$BGP_ROUTER" --region="$REGION" --project="$HOST_PROJECT" \
            --format="value(result.bgpPeerStatus[].status)" | tr ';,' '\n\n' | grep -c '^UP$' || true)
  LEARNED=$(gcloud compute routers get-status "$BGP_ROUTER" --region="$REGION" --project="$HOST_PROJECT" \
            --format="value(result.bestRoutes[].destRange)" | tr ';,' '\n\n' | grep -c '^192.168.0.0/20$' || true)

  pass=0; fail=0
  printf '\n%-36s %-26s %-26s %-6s %s\n' "TEST" "EXPECTED" "ACTUAL" "RESULT" "WHY"
  printf '%.0s-' {1..130}; echo

  row "prod egress IP"                "one of: $PROD_NAT"    "$E_PROD" "$(check_in "$E_PROD" "$PROD_NAT")"   "nat-shared-central-prod"
  row "dev egress IP"                 "$NONPROD_NAT"          "$E_DEV"  "$(check_in "$E_DEV" "$NONPROD_NAT")" "nat-shared-central-nonprod"
  row "fintech egress IP"             "$FIN_NAT"              "$E_FIN"  "$(check_in "$E_FIN" "$FIN_NAT")"     "nat-fintech (own NAT)"
  row "health egress IP"              "$HLT_NAT"              "$E_HLT"  "$(check_in "$E_HLT" "$HLT_NAT")"     "nat-health (own NAT)"
  local DIFF=FAIL; [[ "$E_FIN" != "$E_HLT" && "$E_FIN" != NONE ]] && DIFF=PASS
  row "tenants have different IPs"    "fintech != health"     "$( [[ $DIFF == PASS ]] && echo different || echo same)" "$DIFF" "per-tenant egress identity"
  local P80; P80=$(probe dev-test-vm "$NONPROD_PROJECT" 1.1.1.1 80)
  row "dev -> internet :80"           BLOCKED                 "$P80"    "$( [[ $P80 == BLOCKED ]] && echo PASS || echo FAIL)" "only tcp:443 egress allowed"
  row "BGP sessions up"               "2"                     "$BGP_UP" "$( [[ $BGP_UP == 2 ]] && echo PASS || echo FAIL)" "HA VPN, 2 tunnels"
  row "shared VPC learned on-prem"    "192.168.0.0/20"        "$( [[ $LEARNED -ge 1 ]] && echo 192.168.0.0/20 || echo missing)" "$( [[ $LEARNED -ge 1 ]] && echo PASS || echo FAIL)" "BGP route from onprem-router"
  local O1; O1=$(probe onprem-test-vm "$HOST_PROJECT" "$SVC" 443)
  row "on-prem -> shared-svc :443"    OPEN                    "$O1"     "$( [[ $O1 == OPEN ]] && echo PASS || echo FAIL)" "VPN + allow-onprem-to-shared-svc"
  local O2; O2=$(probe onprem-test-vm "$HOST_PROJECT" "$PRD" 443)
  row "on-prem -> prod :443"          BLOCKED                 "$O2"     "$( [[ $O2 == BLOCKED ]] && echo PASS || echo FAIL)" "only 10.0.0.0/20 advertised"

  printf '\n%d passed, %d failed\n' "$pass" "$fail"
}

failover() {
  local NAT=nat-shared-central-prod ROUTER=nat-router-shared-central-prod
  local NAMES ADDRS BEFORE AFTER CUR_NAME OTHER_NAME OTHER_IP i
  mapfile -t NAMES < <(gcloud compute addresses list --project="$HOST_PROJECT" \
    --filter="name~^nat-shared-central-prod-ip-" --format="value(name)" --sort-by=name)
  mapfile -t ADDRS < <(gcloud compute addresses list --project="$HOST_PROJECT" \
    --filter="name~^nat-shared-central-prod-ip-" --format="value(address)" --sort-by=name)

  BEFORE=$(egress_ip prod-test-vm "$PROD_PROJECT")
  log "Prod currently leaves via $BEFORE (pool: ${ADDRS[*]})"
  for i in "${!ADDRS[@]}"; do
    if [[ "${ADDRS[$i]}" == "$BEFORE" ]]; then CUR_NAME=${NAMES[$i]}; else OTHER_NAME=${NAMES[$i]}; OTHER_IP=${ADDRS[$i]}; fi
  done
  if [[ -z "${CUR_NAME:-}" || -z "${OTHER_NAME:-}" ]]; then echo "Could not match egress IP to the NAT pool"; exit 1; fi

  log "Simulating loss of $CUR_NAME: draining it, keeping only $OTHER_NAME active"
  gcloud compute routers nats update "$NAT" --router="$ROUTER" --region="$REGION" --project="$HOST_PROJECT" \
    --nat-external-ip-pool="$OTHER_NAME" --nat-external-drain-ip-pool="$CUR_NAME"

  log "Waiting 60s for the NAT change to apply"; sleep 60
  AFTER=$(egress_ip prod-test-vm "$PROD_PROJECT")
  printf '\n%-20s %s\n%-20s %s\n%-20s %s\n' "Before:" "$BEFORE" "After:" "$AFTER" "Expected after:" "$OTHER_IP"
  [[ "$AFTER" == "$OTHER_IP" ]] && echo "RESULT: PASS (prod egress failed over with no config change on the VM)" \
                                || echo "RESULT: FAIL"
  log "Restore with Terraform: cd ~/terraform && terraform plan   (shows the drift) && terraform apply"
}

down() {
  exists onprem-test-vm "$HOST_PROJECT" && gcloud compute instances delete onprem-test-vm --project="$HOST_PROJECT" --zone="$ZONE" --quiet
  bash "$HERE/05-security-test.sh" down
}

case "${1:-all}" in
  up)       up ;;
  test)     test_matrix ;;
  failover) failover ;;
  down)     down ;;
  all)      up; log "Waiting 90s for VMs to start"; sleep 90; test_matrix ;;
  *)        echo "Usage: $0 [up|test|failover|down]"; exit 1 ;;
esac
