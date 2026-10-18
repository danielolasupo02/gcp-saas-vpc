#!/usr/bin/env bash
# Phase 7 observability tests
#
# Reuses the Phase 5 test VMs, generates allowed and denied traffic, then checks
# that the logs were collected, exported, turned into metrics and alerts, and
# that Connectivity Tests explain the same allow/deny decisions.
#
# Usage:
#   ./scripts/07-observability-test.sh up        # create the test VMs (Phase 5 set)
#   ./scripts/07-observability-test.sh traffic   # allowed flows + a burst of denied flows
#   ./scripts/07-observability-test.sh verify    # run the test matrix (wait ~5 min after traffic)
#   ./scripts/07-observability-test.sh drift     # change a firewall rule outside Terraform
#   ./scripts/07-observability-test.sh flows     # top talkers from BigQuery
#   ./scripts/07-observability-test.sh down      # delete VMs and connectivity tests
set -euo pipefail

HOST_PROJECT="saas-vpc-host-2022"
PROD_PROJECT="saas-svc-prod-2022"
NONPROD_PROJECT="saas-svc-nonprod-2022"
FINTECH_PROJECT="saas-tenant-fintech-2022"
HEALTH_PROJECT="saas-tenant-health-2022"
LOG_PROJECTS=("$HOST_PROJECT" "$FINTECH_PROJECT" "$HEALTH_PROJECT")
ZONE="us-central1-a"
DATASET="network_flow_logs"
FLOW_TABLE="${HOST_PROJECT}.${DATASET}.compute_googleapis_com_vpc_flows"
BUCKET="${HOST_PROJECT}-network-log-archive"
HERE="$(cd "$(dirname "$0")" && pwd)"

log() { printf '\n==> %s\n' "$*"; }

ip_of() {
  gcloud compute instances describe "$1" --project="$2" --zone="$ZONE" \
    --format='get(networkInterfaces[0].networkIP)'
}

run_on() { # vm project command
  gcloud compute ssh "$1" --project="$2" --zone="$ZONE" --tunnel-through-iap --quiet \
    --command="$3" 2>/dev/null | tail -n1 || true
}

vm_path() { echo "projects/$2/zones/${ZONE}/instances/$1"; }

row() { # name expected actual result
  printf '%-40s %-22s %-22s %s\n' "$1" "$2" "$3" "$4"
  [[ "$4" == PASS ]] && pass=$((pass+1)) || { [[ "$4" == PENDING ]] || fail=$((fail+1)); }
}

# ---------------------------------------------------------------------------

up() { bash "$HERE/05-security-test.sh" up; }

traffic() {
  local PRD SVC HLT
  PRD=$(ip_of prod-test-vm "$PROD_PROJECT")
  SVC=$(ip_of svc-test-vm "$HOST_PROJECT")
  HLT=$(ip_of health-test-vm "$HEALTH_PROJECT")

  log "Allowed: prod -> shared-svc :443 (x5) and prod -> internet :443 via NAT"
  run_on prod-test-vm "$PROD_PROJECT" \
    "for i in 1 2 3 4 5; do curl -s -m 3 -o /dev/null http://$SVC:443; done; curl -s -m 10 -o /dev/null https://api.ipify.org; echo done"

  log "Denied burst: dev -> prod on 30 ports (should trip the firewall-deny alert)"
  run_on dev-test-vm "$NONPROD_PROJECT" \
    "for p in \$(seq 8000 8029); do timeout 1 bash -c '</dev/tcp/$PRD/'\$p 2>/dev/null; done; echo done"

  log "Denied: fintech -> health :443 (tenant isolation)"
  run_on fintech-test-vm "$FINTECH_PROJECT" \
    "timeout 3 bash -c '</dev/tcp/$HLT/443' 2>/dev/null; echo done"

  log "Traffic generated. Wait ~5 minutes for logs to reach BigQuery, then run: verify"
}

create_ct() { # name src-vm src-project dst-vm dst-project port
  if gcloud network-management connectivity-tests describe "$1" --project="$HOST_PROJECT" >/dev/null 2>&1; then
    gcloud network-management connectivity-tests rerun "$1" --project="$HOST_PROJECT" >/dev/null
  else
    gcloud network-management connectivity-tests create "$1" --project="$HOST_PROJECT" \
      --source-instance="$(vm_path "$2" "$3")" \
      --destination-instance="$(vm_path "$4" "$5")" \
      --protocol=TCP --destination-port="$6" >/dev/null
  fi
  gcloud network-management connectivity-tests describe "$1" --project="$HOST_PROJECT" \
    --format='value(reachabilityDetails.result)'
}

verify() {
  local SINKS=0 METRICS=0 P N
  for P in "${LOG_PROJECTS[@]}"; do
    N=$(gcloud logging sinks list --project="$P" --filter='name~^network-' --format='value(name)' | wc -l)
    SINKS=$((SINKS + N))
    N=$(gcloud logging metrics list --project="$P" \
          --filter='name=firewall_denied_count OR name=network_manual_change' --format='value(name)' | wc -l)
    METRICS=$((METRICS + N))
  done

  local ANALYTICS FLOW_ROWS DENIED POLICIES ARCHIVE
  ANALYTICS=$(gcloud logging buckets describe _Default --location=global --project="$HOST_PROJECT" \
                --format='value(analyticsEnabled)' 2>/dev/null || echo False)
  FLOW_ROWS=$(bq query --project_id="$HOST_PROJECT" --use_legacy_sql=false --format=csv --quiet \
                "SELECT COUNT(*) FROM \`${FLOW_TABLE}\` WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)" \
                2>/dev/null | tail -n1 || true)
  [[ "$FLOW_ROWS" =~ ^[0-9]+$ ]] || FLOW_ROWS=0
  DENIED=$(gcloud logging read 'log_id("compute.googleapis.com/firewall") AND jsonPayload.disposition="DENIED"' \
             --project="$HOST_PROJECT" --freshness=2h --limit=200 --format='value(timestamp)' | wc -l)
  POLICIES=$(curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
               "https://monitoring.googleapis.com/v3/projects/${HOST_PROJECT}/alertPolicies" \
               | grep -c '"displayName": "\(NAT\|Firewall\|Network\|HA VPN\|BGP\):' || true)
  ARCHIVE=$(gcloud storage ls "gs://${BUCKET}/" 2>/dev/null | wc -l)

  log "Connectivity Tests (static analysis of routes + firewalls)"
  local CT1 CT2 CT3
  CT1=$(create_ct ct-prod-to-shared-svc-443 prod-test-vm "$PROD_PROJECT" svc-test-vm "$HOST_PROJECT" 443)
  CT2=$(create_ct ct-dev-to-prod-443 dev-test-vm "$NONPROD_PROJECT" prod-test-vm "$PROD_PROJECT" 443)
  CT3=$(create_ct ct-fintech-to-health-443 fintech-test-vm "$FINTECH_PROJECT" health-test-vm "$HEALTH_PROJECT" 443)

  pass=0; fail=0
  printf '\n%-40s %-22s %-22s %s\n' "TEST" "EXPECTED" "ACTUAL" "RESULT"
  printf '%.0s-' {1..95}; echo
  row "log sinks (2 per network project)"   "6"            "$SINKS"   "$( [[ $SINKS == 6 ]] && echo PASS || echo FAIL)"
  row "log-based metrics (2 per project)"   "6"            "$METRICS" "$( [[ $METRICS == 6 ]] && echo PASS || echo FAIL)"
  row "Log Analytics on _Default (host)"    "True"         "$ANALYTICS" "$( [[ $ANALYTICS == True ]] && echo PASS || echo FAIL)"
  row "flow logs in BigQuery (last 1h)"     "> 0 rows"     "$FLOW_ROWS" "$( (( FLOW_ROWS > 0 )) && echo PASS || echo FAIL)"
  row "firewall DENIED logs (last 2h)"      "> 0"          "$DENIED"  "$( (( DENIED > 0 )) && echo PASS || echo FAIL)"
  row "network alert policies"              ">= 4"         "$POLICIES" "$( (( POLICIES >= 4 )) && echo PASS || echo FAIL)"
  row "CT prod -> shared-svc :443"          "REACHABLE"    "$CT1"     "$( [[ $CT1 == REACHABLE ]] && echo PASS || echo FAIL)"
  row "CT dev -> prod :443"                 "UNREACHABLE"  "$CT2"     "$( [[ $CT2 == UNREACHABLE ]] && echo PASS || echo FAIL)"
  row "CT fintech -> health :443"           "UNREACHABLE"  "$CT3"     "$( [[ $CT3 == UNREACHABLE ]] && echo PASS || echo FAIL)"
  row "audit archive in GCS"                "objects"      "$ARCHIVE" "$( (( ARCHIVE > 0 )) && echo PASS || echo PENDING)"

  printf '\n%d passed, %d failed' "$pass" "$fail"
  (( ARCHIVE > 0 )) || printf '  (GCS sinks write in hourly batches; re-run verify later for the archive check)'
  echo
}

drift() {
  log "Changing allow-iap-ssh's description directly (outside Terraform)"
  gcloud compute firewall-rules update allow-iap-ssh --project="$HOST_PROJECT" \
    --description="MANUAL CHANGE - phase 7 drift detection test"
  log "Expect: 'Network: change made outside Terraform' alert email within a few minutes."
  log "Then: cd ~/terraform && terraform plan (shows the drift) && terraform apply (restores it)"
}

flows() {
  log "Top 10 flows by bytes in the last hour (BigQuery)"
  bq query --project_id="$HOST_PROJECT" --use_legacy_sql=false --max_rows=10 \
"SELECT
   jsonPayload.connection.src_ip   AS src_ip,
   jsonPayload.connection.dest_ip  AS dest_ip,
   jsonPayload.connection.dest_port AS dest_port,
   jsonPayload.reporter            AS reporter,
   SUM(SAFE_CAST(jsonPayload.bytes_sent AS INT64)) AS bytes
 FROM \`${FLOW_TABLE}\`
 WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 HOUR)
 GROUP BY 1, 2, 3, 4
 ORDER BY bytes DESC"
}

down() {
  local T
  for T in ct-prod-to-shared-svc-443 ct-dev-to-prod-443 ct-fintech-to-health-443; do
    gcloud network-management connectivity-tests delete "$T" --project="$HOST_PROJECT" --quiet 2>/dev/null || true
  done
  bash "$HERE/05-security-test.sh" down
}

case "${1:-}" in
  up)      up ;;
  traffic) traffic ;;
  verify)  verify ;;
  drift)   drift ;;
  flows)   flows ;;
  down)    down ;;
  *)       echo "Usage: $0 [up|traffic|verify|drift|flows|down]"; exit 1 ;;
esac
