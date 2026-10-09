# Phase 3: Shared VPC Network

## Objective
Build the core Shared VPC from the Phase 2 design: a host project that owns one
network, environment subnets with flow logs, explicit custom routes, a Cloud
Router for BGP, and service projects that may only use their own environment's subnets.

## What Was Built
- Four new projects under the org: 2 service projects, 2 tenant projects (tenants are used in Phase 4)
- Auto-created `default` networks removed from all five projects
- `saas-vpc-host-2022` enabled as the **Shared VPC host**, with prod and nonprod attached as service projects
- `shared-vpc-network`: custom mode, MTU 1460, **GLOBAL** dynamic routing
- 5 subnets with VPC Flow Logs and Private Google Access
- 2 explicit custom static routes (Google's auto-created default route deleted)
- Per-subnet IAM: each service project can only deploy into its own environment's subnets
- Cloud Router `bgp-router-us-central1` (ASN 64512), advertising only the shared services range
- Terraform remote state in a private, versioned Cloud Storage bucket

## Configuration

### Projects

| Project | Role |
|---|---|
| `saas-vpc-host-2022` | Shared VPC host |
| `saas-svc-prod-2022` | Service project: prod |
| `saas-svc-nonprod-2022` | Service project: staging and dev |
| `saas-tenant-fintech-2022` | Tenant (Phase 4) |
| `saas-tenant-health-2022` | Tenant (Phase 4) |

### Subnets (`shared-vpc-network`)

| Subnet | CIDR | Region | Usable by |
|---|---|---|---|
| `shared-svc-subnet` | 10.0.0.0/20 | us-central1 | Host project only |
| `dev-subnet` | 10.10.0.0/20 | us-central1 | `saas-svc-nonprod-2022` |
| `staging-subnet` | 10.20.0.0/20 | us-central1 | `saas-svc-nonprod-2022` |
| `prod-subnet` | 10.30.0.0/20 | us-central1 | `saas-svc-prod-2022` |
| `prod-subnet-east` | 10.30.16.0/20 | us-east1 | `saas-svc-prod-2022` |

Flow logs on every subnet: 5-second aggregation, 50% sampling, all metadata.

### Routes

| Route | Destination | Next hop | Priority | Purpose |
|---|---|---|---|---|
| `private-google-apis` | 199.36.153.8/30 | Internet gateway | 900 | Google APIs from private VMs |
| `default-internet-egress` | 0.0.0.0/0 | Internet gateway | 1000 | Path for Cloud NAT (Phase 6); gated by firewall |

### Cloud Router

| Item | Value |
|---|---|
| Name | `bgp-router-us-central1` |
| ASN | 64512 (on-prem peer will be 64513) |
| Advertisement | Custom: `10.0.0.0/20` only. On-prem never learns dev, staging or prod routes |

### Terraform

| File | Purpose |
|---|---|
| `terraform/backend.tf` | State in `gs://saas-vpc-host-2022-tfstate` (versioned, locked) |
| `terraform/providers.tf` | Google provider, impersonating `network-admin-sa` (no keys) |
| `terraform/main.tf` | Host and service projects, network module call, subnet IAM, Cloud Router |
| `terraform/modules/vpc/` | Reusable VPC module: network, subnets, flow logs, routes (reused for tenants in Phase 4) |
| `scripts/03-shared-vpc-prereqs.sh` | Projects, default network cleanup, IAM, state bucket |

## Verification

| Check | Command |
|---|---|
| Service projects attached | `gcloud compute shared-vpc associated-projects list saas-vpc-host-2022` |
| Subnets | `gcloud compute networks subnets list --network=shared-vpc-network --project=saas-vpc-host-2022` |
| Flow logs + PGA | `gcloud compute networks subnets describe prod-subnet --region=us-central1 --project=saas-vpc-host-2022 --format="yaml(logConfig,privateIpGoogleAccess)"` |
| Routes | `gcloud compute routes list --project=saas-vpc-host-2022 --filter="network~shared-vpc-network"` |
| Cloud Router | `gcloud compute routers describe bgp-router-us-central1 --region=us-central1 --project=saas-vpc-host-2022` |
| No drift | `terraform plan` returns `No changes` |

### Screenshots

#### Prerequisites

**Prerequisites script run**
![Prerequisites script](../screenshots/11-prereqs-script-output.PNG)

**Projects under the organization** (terminal and console)
![Org projects - terminal](../screenshots/12-org-projects.PNG)
![Org projects - console](../screenshots/12-org-projects-gui.PNG)

**Default network removed from the projects** (terminal and console)
![Default network removed - terminal](../screenshots/13-default-network-removed.PNG)
![Default network removed - terminal (cont.)](../screenshots/13b-default-network-removed.PNG)
![Default network removed - console](../screenshots/13b-default-network-removed-gui.PNG)

**Terraform state bucket (versioning on, not public)**
![State bucket](../screenshots/14-state-bucket-gui.PNG)

#### Terraform

**Plan: 20 resources to add**
![Terraform plan](../screenshots/15-terraform-plan.PNG)

**Apply complete**
![Terraform apply](../screenshots/16-terraform-apply.PNG)

#### Shared VPC

**Host project enabled**
![Shared VPC host](../screenshots/17-shared-vpc-host-gui.PNG)

**Attached service projects**
![Service projects attached](../screenshots/18-service-projects-attached-gui.PNG)

#### Network and subnets

**`shared-vpc-network`: custom mode, MTU 1460, global routing**
![Network details](../screenshots/19-vpc-network-details-gui.PNG)

**All five subnets**
![Subnets](../screenshots/20-subnets-list-gui.PNG)

**Flow logs and Private Google Access**
![Flow logs and PGA](../screenshots/21-flow-logs-pga-gui.PNG)

**Subnet-level delegation (Network User per subnet)**
![Subnet IAM delegation](../screenshots/22-subnet-iam-delegation-gui.PNG)

#### Routing

**Custom static routes**
![Custom routes](../screenshots/23-custom-routes-gui.PNG)

**Cloud Router (ASN 64512, advertises 10.0.0.0/20)**
![Cloud Router](../screenshots/24-cloud-router-gui.PNG)

## Notes & Issues

### Billing quota exceeded on the 5th project
`gcloud billing projects link` failed with `Cloud billing quota exceeded` when
linking `saas-tenant-health-2022`. New billing accounts allow only a few linked
projects. Fixed by unlinking an unused project from the billing account, then
re-running the (idempotent) prerequisites script.

### `terraform init` 403: `serviceusage.services.use`
The service account had network and security roles, but every API call is
billed to a quota project, which needs `serviceusage.services.use`. Granted
`roles/serviceusage.serviceUsageConsumer` on the host project and added it to
the prerequisites script.

### Shared VPC host failed: "The project has no organization."
The host project was created in Phase 1 without a parent. The network, subnets,
routes and router were created; the host enablement failed, so the service
attachments and subnet IAM (which depend on it) never ran. Moved the project into
the org with `gcloud beta projects move` and re-applied. Resources already in
state were not recreated; only the remaining 11 were added.

### Cloud Shell reset removed Terraform
Cloud Shell only keeps `$HOME` between sessions. Terraform installed system-wide
disappeared after a reset, so it was reinstalled into `~/bin` and added to `PATH`.

### Destroy and rebuild hit `connection refused`
While destroying and rebuilding to capture clean plan/apply output, some API calls
from Cloud Shell failed with `dial tcp ...:443: connect: connection refused`. This
was a transient network issue, not a code or permission problem. Each run recorded
its progress in state, so re-running with `-parallelism=1` finished the job.

### Decisions
- **Subnet-level `networkUser` instead of project-level:** prod physically cannot place a VM in a dev subnet. Isolation is enforced by IAM before any firewall rule exists.
- **Default route deleted and recreated as code:** every route in the VPC is explicit and reviewable.
- **Custom BGP advertisement:** on-prem only ever learns the shared services range.