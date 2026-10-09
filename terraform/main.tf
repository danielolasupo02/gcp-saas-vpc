###############################################################################
# Phase 3 — Shared VPC host network
#   - Host project enabled for Shared VPC, prod + nonprod service projects attached
#   - shared-vpc-network with 5 subnets, flow logs and Private Google Access
#   - Explicit custom static routes (auto-created default route removed)
#   - Subnet-level IAM: prod project can only use prod subnets, nonprod only dev/staging
#   - Cloud Router for BGP to the (simulated) on-prem network
###############################################################################

locals {
  service_projects = {
    prod    = var.prod_service_project_id
    nonprod = var.nonprod_service_project_id
  }

  shared_subnets = {
    "shared-svc-subnet" = {
      cidr        = "10.0.0.0/20"
      region      = var.primary_region
      description = "Shared services consumed by environments and tenants"
    }
    "dev-subnet" = {
      cidr        = "10.10.0.0/20"
      region      = var.primary_region
      description = "Development environment"
    }
    "staging-subnet" = {
      cidr        = "10.20.0.0/20"
      region      = var.primary_region
      description = "Staging environment"
    }
    "prod-subnet" = {
      cidr        = "10.30.0.0/20"
      region      = var.primary_region
      description = "Production environment (primary region)"
    }
    "prod-subnet-east" = {
      cidr        = "10.30.16.0/20"
      region      = var.secondary_region
      description = "Production environment (secondary region)"
    }
  }

  # Which service project may deploy into which subnet.
  # shared-svc-subnet is intentionally not delegated: only the host project uses it.
  subnet_delegation = {
    "prod-subnet"      = "prod"
    "prod-subnet-east" = "prod"
    "staging-subnet"   = "nonprod"
    "dev-subnet"       = "nonprod"
  }
}

# --- Shared VPC host and service projects ------------------------------------

resource "google_compute_shared_vpc_host_project" "host" {
  project = var.host_project_id
}

resource "google_compute_shared_vpc_service_project" "service" {
  for_each = local.service_projects

  host_project    = google_compute_shared_vpc_host_project.host.project
  service_project = each.value
}

# --- Network, subnets, custom routes -----------------------------------------

module "shared_vpc" {
  source = "./modules/vpc"

  project_id            = var.host_project_id
  network_name          = "shared-vpc-network"
  description           = "Shared VPC for prod, staging, dev and shared services"
  routing_mode          = "GLOBAL"
  mtu                   = 1460
  delete_default_routes = true
  subnets               = local.shared_subnets

  flow_logs = {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  routes = {
    "private-google-apis" = {
      dest_range  = "199.36.153.8/30"
      priority    = 900
      description = "private.googleapis.com: Google API traffic stays on Google's network"
    }
    "default-internet-egress" = {
      dest_range  = "0.0.0.0/0"
      priority    = 1000
      description = "Explicit internet route for Cloud NAT; access still gated by egress firewall rules"
    }
  }
}

# --- Subnet-level delegation to service projects ------------------------------

data "google_project" "service" {
  for_each   = local.service_projects
  project_id = each.value
}

locals {
  # Identities in each service project that create resources in shared subnets:
  # the Google APIs service agent (managed instance groups etc.) and the default Compute SA.
  service_principals = {
    for key, p in data.google_project.service : key => [
      "serviceAccount:${p.number}@cloudservices.gserviceaccount.com",
      "serviceAccount:${p.number}-compute@developer.gserviceaccount.com",
    ]
  }

  subnet_bindings = merge([
    for subnet, env in local.subnet_delegation : {
      for idx, member in local.service_principals[env] :
      "${subnet}-${idx}" => {
        subnet = subnet
        member = member
      }
    }
  ]...)
}

resource "google_compute_subnetwork_iam_member" "network_user" {
  for_each = local.subnet_bindings

  project    = var.host_project_id
  region     = module.shared_vpc.subnets[each.value.subnet].region
  subnetwork = each.value.subnet
  role       = "roles/compute.networkUser"
  member     = each.value.member

  depends_on = [google_compute_shared_vpc_service_project.service]
}

# --- Cloud Router for BGP (HA VPN to on-prem is added in Phase 6) -------------

resource "google_compute_router" "bgp" {
  project     = var.host_project_id
  name        = "bgp-router-${var.primary_region}"
  description = "BGP router for hybrid connectivity to on-prem"
  region      = var.primary_region
  network     = module.shared_vpc.network_self_link

  bgp {
    asn                = var.bgp_asn
    advertise_mode     = "CUSTOM"
    keepalive_interval = 20

    # On-prem only learns the shared services range, never dev/staging/prod.
    advertised_ip_ranges {
      range       = local.shared_subnets["shared-svc-subnet"].cidr
      description = "shared-svc-subnet"
    }
  }
}
