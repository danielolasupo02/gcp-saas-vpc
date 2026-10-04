# Phase 1 — Project Setup & IAM

## Objective
Create a dedicated Google Cloud project for the multi-tenant SaaS network,
enable the APIs required for network management, set up a least-privilege
service account for infrastructure changes, and put cost guardrails in place
before any billable resources are created.

## What Was Built
- A dedicated Google Cloud project under the organization, which will serve as the **Shared VPC host project**
- Billing linked to an open billing account
- Compute Engine (VPC), networking, security and observability APIs enabled
- A custom service account, `network-admin-sa`, with network and firewall admin roles
- Keyless access: engineers impersonate the service account instead of using JSON keys
- A billing budget with alerts at 50%, 90% and 100%

## Configuration

### Project

| Item | Value |
|---|---|
| Project name | Enterprise SaaS VPC Project |
| Project ID | `saas-vpc-host-2022` |
| Project number | `231456483426` |
| Organization | `danielolasupo02-org` (`172544480375`) |
| Role in architecture | Shared VPC host project |

### Enabled APIs

| API | Purpose |
|---|---|
| `compute.googleapis.com` | Compute Engine and VPC networking (networks, subnets, firewall, routes, NAT, routers) |
| `vpcaccess.googleapis.com` | Serverless VPC Access |
| `iam.googleapis.com` | Service accounts and IAM |
| `cloudresourcemanager.googleapis.com` | Project and organization management |
| `logging.googleapis.com` | VPC Flow Logs, firewall logs, audit logs |
| `monitoring.googleapis.com` | Network dashboards and alerting |
| `dns.googleapis.com` | Private Cloud DNS zones |
| `iap.googleapis.com` | Identity-Aware Proxy for admin SSH |
| `billingbudgets.googleapis.com` | Budget alerts |

### Service account

| Item | Value |
|---|---|
| Name | `network-admin-sa` |
| Display name | Network Admin Service Account |
| Email | `network-admin-sa@saas-vpc-host-2022.iam.gserviceaccount.com` |
| Roles | `roles/compute.networkAdmin`, `roles/compute.securityAdmin` |
| Authentication | Impersonation (`roles/iam.serviceAccountTokenCreator` granted to the engineer). No keys created. |

**Why two roles?** `roles/compute.networkAdmin` manages networks, subnets,
routes, routers and NAT, but Google deliberately excludes firewall rules from it.
`roles/compute.securityAdmin` adds firewall rule and policy management, which
Phases 4 and 5 require.

**Why impersonation instead of a key?** Service account keys are long-lived
credentials that can leak through laptops, repos or CI logs. With impersonation,
short-lived tokens are issued on demand, access is controlled by IAM, and every
use appears in audit logs.

### Cost guardrails

| Item | Value |
|---|---|
| Budget name | `saas-vpc-budget` |
| Amount | $20 USD |
| Scope | `saas-vpc-host-2022` |
| Alert thresholds | 50%, 90%, 100% |

Phase 1 resources (project, APIs, IAM, budget) cost nothing. Billable resources
start in Phase 3, and they are destroyed at the end of each working session with
`terraform destroy`.

### Commands
The full command set is in [`scripts/01-project-setup.sh`](../scripts/01-project-setup.sh).

## Verification

| Check | Command | Result |
|---|---|---|
| Organization exists | `gcloud organizations list` | `danielolasupo02-org` (`172544480375`) |
| Project under organization | `gcloud projects describe saas-vpc-host-2022 --format="value(parent)"` | Parent is organization `172544480375` |
| Billing enabled | `gcloud billing projects describe saas-vpc-host-2022` | `billingEnabled: true` |
| APIs enabled | `gcloud services list --enabled` | All APIs listed above present |
| Service account roles | `gcloud projects get-iam-policy saas-vpc-host-2022 --flatten="bindings[].members" --filter="bindings.members:network-admin-sa@saas-vpc-host-2022.iam.gserviceaccount.com" --format="table(bindings.role)"` | `compute.networkAdmin`, `compute.securityAdmin` |
| Impersonation works | `gcloud compute networks list --impersonate-service-account=network-admin-sa@saas-vpc-host-2022.iam.gserviceaccount.com` | Command succeeds as the service account |

### Screenshots

**Project dashboard**
![Project dashboard](screenshots/p1-01-project-dashboard.png)

**Billing linked**
![Billing linked](screenshots/p1-02-billing-linked.png)

**Enabled APIs**
![Enabled APIs](screenshots/p1-03-apis-enabled.png)

**Service account**
![Service account](screenshots/p1-04-service-account.png)

**IAM roles**
![IAM roles](screenshots/p1-05-iam-roles.png)

**Impersonation test**
![Impersonation test](screenshots/p1-06-impersonation-test.png)

**Budget alert**
![Budget alert](screenshots/p1-07-budget-alert.png)

## Notes & Issues

### Issue: API enablement failed because the billing account was closed
**Symptom**
```
ERROR: (gcloud.services.enable) FAILED_PRECONDITION: Billing account for project
'231456483426' is not open. Billing must be enabled for activation of service(s)
'compute.googleapis.com,dns.googleapis.com,vpcaccess.googleapis.com' to proceed.
```

**Cause:** The setup script picked the first billing account returned by
`gcloud billing accounts list --limit=1`. That account was closed.

**Fix:** Listed billing accounts, identified the one with `OPEN: True`, and
relinked the project:
```bash
gcloud billing accounts list
gcloud billing projects link saas-vpc-host-2022 --billing-account=<OPEN_ACCOUNT_ID>
```
Then re-ran API enablement and created the budget against the open account.

**Lesson:** Never auto-select a billing account in scripts. Filter on open
accounts (`--filter="open=true"`) or pass the ID explicitly.

### Decision: firewall permissions added up front
`compute.networkAdmin` alone would have caused permission errors when Terraform
created firewall rules in Phase 4. `compute.securityAdmin` was granted during
setup to avoid this.

### Decision: Shared VPC requires an organization
`gcloud compute shared-vpc host enable` only works on projects inside an
organization. The account has an organization (`172544480375`), so this project
can act as a real Shared VPC host in Phase 3 rather than a single-project simulation.