# Phase 7: Network Monitoring and Logging

## Objective
Make every network decision observable and auditable. Collect flow logs at a
sampling rate that matches each environment's risk. Export network logs to
analytics and long-term storage. Turn security-relevant events into metrics, and
alert on NAT problems, firewall deny spikes, and any network change made outside
Terraform.

## What Was Built

| Layer | What | Module |
|---|---|---|
| Collect | VPC flow logs on every subnet, with sampling set per subnet | `modules/vpc` |
| Export | Flow logs → BigQuery `network_flow_logs` (daily partitions, 30-day expiry)<br>Firewall, NAT, DNS and network admin audit logs → GCS `saas-vpc-host-2022-network-log-archive` (Coldline after 30 days, deleted after 365) | `modules/logging` |
| Detect | Log-based metrics in host, fintech and health: `firewall_denied_count` (labelled by rule), `network_manual_change` (labelled by principal and method) | `modules/logging` |
| Alert | Email channel and 4 policies: NAT packets dropped, NAT port allocation failed, firewall deny spike, change made outside Terraform (VPN/BGP alerts are created when `enable_hybrid_vpn = true`) | `modules/monitoring` |
| See | "Network Security & Health" dashboard, Log Analytics on `_Default` for Flow Analyzer, Connectivity Tests | both |

27 resources added and 6 subnets updated in place, with no destroys.

## Configuration

### Flow log sampling (per-subnet override in `modules/vpc`)

| Subnet | Sampling | Why |
|---|---|---|
| `prod-subnet`, `prod-subnet-east` | 100% | Production audit trail |
| `fintech-subnet`, `health-subnet` | 100% | Regulated tenants |
| `shared-svc-subnet` | 50% | Network default |
| `dev-subnet`, `staging-subnet` | 25% | Lower risk, lower cost |

All subnets use 5-second aggregation and include all metadata.

### Log export

| Sink (in host, fintech, health) | Filter | Destination |
|---|---|---|
| `network-flows-to-bq` | `compute.googleapis.com/vpc_flows` | BigQuery `saas-vpc-host-2022.network_flow_logs` |
| `network-audit-to-gcs` | firewall, `nat_flows`, `dns_queries`, compute Admin Activity audit | GCS archive bucket |

Each sink has its own writer identity, which is granted only `bigquery.dataEditor`
on the dataset or `storage.objectCreator` on the bucket. Tenant sinks write into
the host project, so logs are centralised without giving tenants access to each
other's data.

### Alert policies

| Policy | Signal | Fires when |
|---|---|---|
| NAT: packets dropped | `nat/dropped_sent_packets_count` | > 0 for 5 minutes |
| NAT: port allocation failed | `nat/nat_allocation_failed` | any failure |
| Firewall: denied connections spike | `user/firewall_denied_count` (`gce_subnetwork`) | > 20 denies in 5 minutes |
| Network: change made outside Terraform | `user/network_manual_change` | any change by an identity other than the Terraform SA |

Each policy carries a runbook in its documentation field. The host project is
the metrics scope (Phase 6), so one policy covers every project.

## Verification

### Observability test (10/10 PASS)

| Test | Expected | Actual |
|---|---|---|
| Log sinks (2 per network project) | 6 | 6 |
| Log-based metrics (2 per project) | 6 | 6 |
| Log Analytics on `_Default` | True | True |
| Flow logs in BigQuery (last 1h) | > 0 rows | 128 |
| Firewall DENIED logs | > 0 | 30 |
| Network alert policies | ≥ 4 | 4 |
| Connectivity Test prod → shared-svc :443 | REACHABLE | REACHABLE |
| Connectivity Test dev → prod :443 | UNREACHABLE | UNREACHABLE |
| Connectivity Test fintech → health :443 | UNREACHABLE | UNREACHABLE |
| Audit archive in GCS | objects | 3 |

### Detection end to end

| Scenario | Evidence |
|---|---|
| 30 denied connections, dev → prod | The firewall-deny alert fired: `firewall_denied_count ... above the threshold of 20 with a value of 30`. The rule label was `deny-egress-private-ranges` |
| Manual change to `allow-iap-ssh` | `network_manual_change` = 1, with `principal` = admin user and `method` = `v1.compute.firewalls.patch` |
| Drift | `terraform plan`: `description "MANUAL CHANGE…" -> "Admin SSH only via Identity-Aware Proxy TCP forwarding"`, 1 to change. After apply: `No changes` |
| Path analysis | Connectivity Test dev → prod: dropped by egress rule `deny-egress-private-ranges`, 0/50 packets delivered on the live data plane |

### Commands

| Check | Command |
|---|---|
| Tests | `bash scripts/07-observability-test.sh up && ... traffic && ... verify` |
| Top talkers | `bash scripts/07-observability-test.sh flows` |
| Drift test | `bash scripts/07-observability-test.sh drift`, then `terraform plan` / `apply` |
| Sinks | `gcloud logging sinks list --project=saas-tenant-fintech-2022 --format="table(name,destination)"` |
| Metric resource type | `timeSeries` API with `filter=metric.type="logging.googleapis.com/user/firewall_denied_count"` |

### Screenshots

#### Terraform and collection

**Plan (27 to add, 6 to change, 0 to destroy)**
![Terraform plan](../screenshots/56-terraform-plan.PNG)

**Flow log sampling per subnet**
![Flow log sampling](../screenshots/58-flow-logs-prod-gui.PNG)

#### Export

**Log Router: host project sinks**
![Log router sinks](../screenshots/59-log-router-sinks-gui.PNG)

**Log Router: fintech sinks write to the host project**
![Fintech sinks](../screenshots/59b-log-router-fintech-gui.PNG)

**BigQuery flow-log dataset (partitioned table)**
![BigQuery dataset](../screenshots/60-bigquery-dataset-gui.PNG)

**Top talkers from BigQuery**
![Top talkers](../screenshots/61-bigquery-top-talkers-gui.PNG)

**Archive bucket lifecycle (Coldline 30 days, delete after 365)**
![Log archive bucket](../screenshots/62-log-archive-bucket-gui.PNG)

#### Detect and alert

**Log-based metrics**
![Log-based metrics](../screenshots/63-log-based-metrics-gui.PNG)

**Alert policies**
![Alert policies](../screenshots/64-alert-policies-gui.PNG)

**Email notification channel**
![Notification channel](../screenshots/65-notification-channel-gui.PNG)

**Network Security & Health dashboard**
![Network dashboard](../screenshots/66-network-dashboard-gui.PNG)

**Flow Analyzer**
![Flow Analyzer](../screenshots/67-flow-analyzer-gui.PNG)

#### Connectivity Tests

**1 reachable, 2 unreachable**
![Connectivity tests](../screenshots/68-connectivity-tests-gui.PNG)

**dev → prod dropped by `deny-egress-private-ranges`**
![CT dev to prod](../screenshots/68b-ct-dev-to-prod-gui.PNG)

#### Tests and incidents

**Observability test: 10/10 PASS**
![Observability test](../screenshots/70-observability-test.PNG)

**Firewall deny spike: alert firing**
![Firewall deny incident](../screenshots/71-firewall-deny-incident-gui.PNG)

**Alert email**
![Alert email](../screenshots/71b-alert-email.PNG)

**Change made outside Terraform: who and what**
![Manual change](../screenshots/72-manual-change-incident-gui.PNG)

**Terraform detects the drift**
![Drift plan](../screenshots/72b-drift-plan.PNG)

**Restored, no drift**
![Drift restored](../screenshots/72c-drift-restored.PNG)

## Notes & Issues

### `modules/vpc` not updated in Cloud Shell
Unzipping the Phase 7 bundle skipped the existing `modules/vpc` folder, so `terraform validate` failed with `module.shared_vpc ... no attribute named "flow_logs"`. The three module files were rewritten with heredocs, and each change was confirmed with `grep -c` before running plan.

### Alert filters must name a resource type
Both log-metric alerts first failed with `400: must specify a restriction on "resource.type"`. The type was first guessed as `global`, but the alert never fired. The `timeSeries` API showed that `firewall_denied_count` is written under `gce_subnetwork` (the firewall log's resource). The filter was fixed and the burst re-run, and the alert then fired at 30 denies. The manual-change alert uses `one_of("global", "gce_router", "vpn_gateway")`, which matched the `firewalls.patch` event.

### GCS sink showed "Starting up", 0 B
This is expected: Cloud Storage sinks write in hourly batches. The BigQuery sink showed data within minutes. The archive had objects within the hour.

### DENIED check failed on the first run
The check only looked back 30 minutes and the traffic was older than that. The window was widened to 2 hours.

### Cloud Shell lost its credentials
Mid-session, gcloud returned `service account info is missing 'email'` and Terraform returned `invalid token JSON from metadata`. Fixed with `gcloud auth login --update-adc`. Terraform was then given a token directly with `export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)`; impersonation of the Terraform SA was unchanged.

### Subnet pages no longer show flow-log settings
Neither the details page nor the edit page shows flow-log settings any more. They were verified with `gcloud compute networks subnets list --format="table(...logConfig.flowSampling...)"`.

### Network Topology showed no data
Topology is built from aggregated VM traffic metrics with roughly an hour's delay, so lab-scale traffic didn't register. Flow Analyzer and BigQuery were used for traffic analysis instead.

### Decisions
- **Sampling follows risk.** Full fidelity where audits need it (prod, regulated tenants); 25% on dev and staging to control cost.
- **Two destinations.** BigQuery for fast, short-lived analytics; GCS Coldline for cheap long retention. In production the bucket would get a locked retention policy; here `force_destroy` keeps the lab removable.
- **Drift is a security signal.** Any change by an identity other than the Terraform SA alerts with who made it and which method was called, and `terraform plan` shows exactly what changed.
- **Alerts in the scoping project.** The same metric name in every project means one policy covers the host and all tenants.