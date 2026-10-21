# Network Disaster Recovery Runbook

How the multi-tenant SaaS network is protected, and the exact steps to recover
it. This applies to `shared-vpc-network`, `customer-fintech-vpc`,
`customer-health-vpc`, egress (Cloud NAT), hybrid connectivity (HA VPN + BGP),
security controls and the logging/monitoring pipeline.

## Recovery objectives

| Item | Target | How it's met |
|---|---|---|
| **RPO**, network configuration | 0 for changes made through Terraform; ≤ 24h for anything else | All config is in Git and the versioned Terraform state; daily config backup |
| **RTO**, single object deleted or changed | < 15 min | Detected by the drift alert and nightly CI plan; restored with `terraform apply` |
| **RTO**, loss of us-central1 | < 1 h for the network layer | Pilot-light DR region already provisioned; one variable enables tenant DR egress |
| **RTO**, Terraform state lost or corrupted | < 30 min | Restore a previous generation from the versioned state bucket |

Workload data and VM recovery are out of scope: they belong to the application
DR plan. This runbook guarantees that the network is there for them to land on.

## DR design

**Regions:** primary `us-central1`, DR `us-east1` (pilot light). The DR subnets
exist and cost nothing at rest.

| Network | Primary (us-central1) | DR (us-east1) |
|---|---|---|
| `shared-vpc-network`: prod | `prod-subnet` 10.30.0.0/20 | `prod-subnet-east` 10.30.16.0/20 |
| `shared-vpc-network`: shared services | `shared-svc-subnet` 10.0.0.0/20 | `shared-svc-subnet-east` 10.0.16.0/20 |
| `shared-vpc-network`: dev / staging | 10.10.0.0/20, 10.20.0.0/20 | none (not business-critical) |
| `customer-fintech-vpc` | `fintech-subnet` 10.100.0.0/20 | `fintech-subnet-east` 10.100.16.0/20 |
| `customer-health-vpc` | `health-subnet` 10.110.0.0/20 | `health-subnet-east` 10.110.16.0/20 |

| Layer | DR behaviour |
|---|---|
| Routing | Shared VPC uses GLOBAL dynamic routing. Peering exports DR subnet routes automatically |
| Firewall | Rules use /16 blocks and service accounts; all shared-svc rules include both ranges, so **no security change is needed to fail over** |
| Egress | `nat-shared-east-prod` (1 static IP) is always on. Tenant DR NAT is created by `enable_dr_egress = true` |
| Hybrid | On-prem is advertised both shared-svc ranges. A second HA VPN in us-east1 would be added for full hybrid DR (not built: cost) |
| Guardrails | `modules/vpc` refuses to plan a network missing a subnet in either required region |
| Observability | Sinks, metrics and alerts are global or project-level and need no failover. The config backup bucket lives in us-east1 |

## What is backed up, and where

| Asset | Protection | Location | Retention |
|---|---|---|---|
| Terraform code | Git (GitHub `danielolasupo02/gcp-saas-vpc`) | GitHub | Full history |
| Terraform state | GCS object versioning | `gs://saas-vpc-host-2022-tfstate` (prefix `network`) | All versions |
| Live network config | `scripts/backup_config.sh`, daily via CI | `gs://saas-vpc-host-2022-network-config-backups` (us-east1, versioned) | 180 days |
| Network logs | Log sinks (Phase 7) | BigQuery (30 days), GCS archive (365 days) | As stated |

Each config backup is a `.tar.gz` of YAML/JSON exports for 5 projects plus the
org firewall policy and org policies, with a `MANIFEST.sha256` and an archive
checksum. It never contains secrets: the Terraform state isn't copied because it
holds the VPN pre-shared key, and VPN secrets are redacted.

```bash
bash scripts/backup_config.sh backup              # new backup, prints the ID
bash scripts/backup_config.sh list
bash scripts/backup_config.sh verify <id>         # checksums
bash scripts/backup_config.sh diff <id> live      # what changed since the backup
bash scripts/backup_config.sh diff <id1> <id2>    # what changed between two backups
```

## Scenarios

### 1. Object deleted or changed outside Terraform
**Detect:** the email alert "Network: change made outside Terraform" (names who
made the change and the API method), or the scheduled CI run failing on drift.

1. Find what changed: `bash scripts/backup_config.sh diff <latest-id> live`
2. Confirm with the actor whether it was an approved break-glass change.
3. If it wasn't approved, restore: `cd terraform && terraform plan` (review), then `terraform apply`.
4. If it was approved, codify it in Terraform through a pull request, so the next plan is clean.
5. Verify: `terraform plan` → `No changes`, and re-run the relevant test script.

### 2. Loss of us-central1 (regional outage)
**Detect:** NAT, VPN and BGP alerts; workloads in us-central1 unreachable.

1. Enable tenant DR egress, if tenants need internet in the DR region:
   ```bash
   cd terraform
   sed -i 's/^enable_dr_egress.*/enable_dr_egress = true/' terraform.tfvars
   terraform plan -out=dr.tfplan && terraform apply dr.tfplan
   ```
   Give tenants the new egress IPs (`terraform output nat_gateways`) for their allowlists.
2. Deploy or scale workloads into `prod-subnet-east`, `shared-svc-subnet-east` and `<tenant>-subnet-east`. Workload identities and firewall rules already apply.
3. Point DNS at the DR endpoints. Internal names live in `saas.internal`; update A records through Terraform.
4. Verify: `bash scripts/08-dr-test.sh test`.
5. **Fail back:** when us-central1 recovers, move workloads back, set `enable_dr_egress = false` and apply.

Note that Cloud Router and the HA VPN are regional. Until a DR VPN is built,
on-prem connectivity is unavailable during a us-central1 outage. That's an
accepted risk, recorded above.

### 3. NAT egress IP blocked or must be rotated
Prod has two NAT IPs. Drain the bad one; traffic moves to the other with no VM change:
```bash
gcloud compute routers nats update nat-shared-central-prod --router=nat-router-shared-central-prod \
  --region=us-central1 --project=saas-vpc-host-2022 \
  --nat-external-ip-pool=<good-ip-name> --nat-external-drain-ip-pool=<bad-ip-name>
```
To restore, release the drained IP first (the API won't move an IP from drain
straight back to active), then let Terraform add it back:
```bash
gcloud compute routers nats update ... --nat-external-ip-pool=<good-ip-name> --clear-nat-external-drain-ip-pool
cd terraform && terraform apply
```

### 4. HA VPN tunnel or BGP session down
One tunnel down: traffic continues on the second tunnel. Check
`gcloud compute routers get-status bgp-router-us-central1 --region=us-central1 --project=saas-vpc-host-2022`
and `gcloud compute vpn-tunnels describe <tunnel> --region=us-central1`, then the peer side.
Both down: on-prem → shared-svc is unavailable. Check the peer gateway. If the
config was changed, scenario 1 applies.

### 5. Terraform state lost or corrupted
```bash
gcloud storage ls -a gs://saas-vpc-host-2022-tfstate/network/default.tfstate     # list generations
gcloud storage cp "gs://saas-vpc-host-2022-tfstate/network/default.tfstate#<generation>" \
  gs://saas-vpc-host-2022-tfstate/network/default.tfstate
cd terraform && terraform plan    # should show no unexpected changes
```
If no good version exists, rebuild state with `terraform import`, using the
latest config backup as the list of what exists. If a lock is stuck after a
crash, run `terraform force-unlock <ID>`.

### 6. Credentials compromised
1. Disable CI access immediately: `gcloud iam workload-identity-pools providers disable github-oidc --workload-identity-pool=github --location=global --project=saas-vpc-host-2022`
2. If the Terraform SA is suspected: `gcloud iam service-accounts disable network-admin-sa@saas-vpc-host-2022.iam.gserviceaccount.com`. No keys exist to revoke, because key creation is blocked by org policy.
3. Review Admin Activity audit logs (GCS archive and `_Required` bucket) for changes by that identity.
4. Compare live config with the last known-good backup: `backup_config.sh diff <id> live`.
5. Re-enable, then `terraform plan` / `apply` to remove anything the attacker changed.

## Testing

| Test | Frequency | How |
|---|---|---|
| Config backup | Daily (CI) | `terraform.yml` backup job |
| Drift check | Daily (CI) | Scheduled plan fails on any difference |
| DR readiness | Quarterly, and after network changes | `bash scripts/08-dr-test.sh up && ... test` |
| Deletion recovery drill | Quarterly | `bash scripts/08-dr-test.sh drill` (measures RTO) |
| NAT failover | Quarterly | `bash scripts/06-egress-test.sh failover` |

### Last drill
| Date | Test | Result | RTO |
|---|---|---|---|
| _pending_ | DR readiness matrix | | n/a |
| _pending_ | Firewall rule deletion drill | | |

## Contacts and access
- **Network owner:** platform team (repo admins on GitHub).
- **Break-glass:** org admin user, who impersonates `network-admin-sa` for Terraform. Every break-glass change raises the manual-change alert by design.
