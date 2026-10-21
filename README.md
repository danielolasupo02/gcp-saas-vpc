# gcp-saas-vpc

Production-style Google Cloud network for a multi-tenant SaaS platform serving
fintech and healthcare customers. It's built in 8 phases with Terraform: Shared
VPC, isolated tenant VPCs, zero-trust firewalls, controlled egress, hybrid
connectivity, observability, disaster recovery and keyless CI/CD.

![Shared VPC, Cloud NAT and HA VPN architecture](screenshots/gcp-shared-vpc-nat-ha-vpn-architecture.PNG)

## Highlights

- **Hub-and-spoke multi-tenancy:** a Shared VPC host for prod, staging and dev. Each tenant has its own project and VPC, peered to shared services only. Tenants can never reach each other, enforced by routing (non-transitive peering), VPC firewalls and an org-level firewall policy.
- **Zero trust:** default-deny ingress and egress, rules targeted by service account, IAP-only admin access with OS Login, no public IPs (org policy), no service account keys (org policy), and private DNS for Google APIs.
- **Controlled egress:** one Cloud NAT per environment and tenant, with fixed IPs that customers can allowlist. Prod has two IPs for drain-based failover; HTTPS is the only internet egress allowed.
- **Hybrid:** HA VPN (2 tunnels) with BGP to a simulated on-prem network. On-prem only ever learns the shared-services ranges.
- **Observability:** flow logs sampled per subnet according to risk, logs exported to BigQuery and a GCS archive, log-based metrics, and alerts for NAT problems, firewall-deny spikes and **any change made outside Terraform**.
- **Disaster recovery:** a pilot-light DR region (us-east1), checksummed config backups stored in the DR region, and a documented runbook. A measured drill restored a deleted firewall rule in **249 s**.
- **Keyless CI/CD:** GitHub Actions authenticated with Workload Identity Federation. Pull requests get a plan comment, applies need approval, and a daily job checks for drift and takes a backup.

## Phases

| # | Phase | Doc | Tests |
|---|---|---|---|
| 1 | Project setup, IAM, budget | [01-project-setup](docs/01-project-setup.md) | n/a |
| 2 | Architecture and IP plan | [02-architecture-design](docs/02-architecture-design.md) | n/a |
| 3 | Shared VPC, subnets, routes, Cloud Router | [03-shared-vpc](docs/03-shared-vpc.md) | n/a |
| 4 | Tenant VPCs and peering | [04-network-peering](docs/04-network-peering.md) | 7/7 |
| 5 | Security controls | [05-security-controls](docs/05-security-controls.md) | 12/12 |
| 6 | Egress (Cloud NAT) and hybrid (HA VPN + BGP) | [06-egress-management](docs/06-egress-management.md) | 10/10 + NAT failover |
| 7 | Monitoring and logging | [07-monitoring-logging](docs/07-monitoring-logging.md) | 10/10 + alerts fired |
| 8 | Automation, backup and DR | [08-automation-dr](docs/08-automation-dr.md) · [DR runbook](docs/dr_network_config.md) | 8/8 + drill (RTO 249 s) |

## Address plan

| Range | Use |
|---|---|
| 10.0.0.0/20, 10.0.16.0/20 | Shared services (us-central1, us-east1) |
| 10.10.0.0/16 | Dev |
| 10.20.0.0/16 | Staging |
| 10.30.0.0/16 | Prod (10.30.0.0/20 central, 10.30.16.0/20 east) |
| 10.100.0.0/16 | Tenant: fintech |
| 10.110.0.0/16 | Tenant: healthcare |
| 192.168.0.0/20 | Simulated on-prem |

## Repository layout

```
terraform/
  main.tf             Shared VPC host, subnets, routes, Cloud Router, identities
  vpc_peering.tf      Tenant VPCs + hub-and-spoke peering
  firewall_rules.tf   Peering and IAP rules
  security.tf         Org firewall policy, org policies, zero-trust rules, private DNS
  egress.tf           Cloud NAT gateways, simulated on-prem, HA VPN + BGP, dashboard
  observability.tf    Logging + monitoring modules
  dr.tf               Config backup bucket (DR region)
  modules/
    vpc/              Network, subnets (per-subnet flow logs), routes, DR guardrails
    egress/           Cloud Router + static IPs + Cloud NAT
    logging/          Sinks, BigQuery, GCS archive, log-based metrics
    monitoring/       Alert policies, notification channel, dashboard
scripts/              Per-phase prerequisites and test scripts, backup_config.sh
docs/                 One document per phase + DR runbook
.github/workflows/    terraform.yml (plan / approved apply / drift / backup)
screenshots/          Evidence referenced by the docs
```

## Running it

Prerequisites: a GCP organization, the 5 projects from Phase 1/3, and Terraform ≥ 1.5.

```bash
# one-time setup per phase (APIs, service accounts, IAM; kept outside Terraform on purpose)
bash scripts/03-shared-vpc-prereqs.sh   # ... through 08-cicd-prereqs.sh

cd terraform
cp terraform.tfvars.example terraform.tfvars    # set alert_email
terraform init && terraform plan && terraform apply
```

All Terraform runs as `network-admin-sa` through impersonation; no keys exist
anywhere. After CI/CD is set up, changes go through pull requests instead of
local applies.

## Tear down and rebuild

To stop all costs and keep the code:

1. Disable the scheduled workflow: **Actions → terraform → ⋯ → Disable workflow**.
2. Keep the org's built-in key-creation policy out of the destroy:
   ```bash
   terraform state rm 'google_org_policy_policy.boolean["iam.disableServiceAccountKeyCreation"]'
   ```
3. Run `terraform destroy`.

To rebuild:
```bash
terraform import 'google_org_policy_policy.boolean["iam.disableServiceAccountKeyCreation"]' \
  organizations/172544480375/policies/iam.disableServiceAccountKeyCreation
terraform apply
```
Then re-enable the workflow.

## Lessons learned

Each phase doc ends with Notes & Issues. A selection:
- A Shared VPC host must be inside an organization; firewall logs for service-project VMs land in the **host** project.
- The API won't move a drained NAT IP straight back to active; it has to be released from the drain pool first.
- The Monitoring API rewrites dashboard JSON, so Terraform must send the same shape or it reports a diff on every plan.
- Alert filters on log-based metrics must name the right `resource.type`. The timeSeries API settled it (`gce_subnetwork`, not `global`).
- Unattended scripts must disable gcloud prompts, or they hang on a hidden "enable API?" question.
