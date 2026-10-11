###############################################################################
# Phase 4 — Tenant VPCs and VPC Network Peering (hub-and-spoke)
#
#   shared-vpc-network (hub)
#     ├── peered ── customer-fintech-vpc (10.100.0.0/20)
#     └── peered ── customer-health-vpc  (10.110.0.0/20)
#
#   - Each tenant gets its own project and VPC (hard network boundary).
#   - Peering is non-transitive: fintech and healthcare have no route to each other.
#   - Custom routes are NOT exchanged: tenants only learn subnet routes, never
#     the shared VPC's internet route or (later) on-prem BGP routes.
#   - Onboarding a tenant = one new entry in local.tenants + its two peerings.
###############################################################################

locals {
  tenants = {
    fintech = {
      project_id     = var.fintech_project_id
      subnet_cidr    = "10.100.0.0/20"
      reserved_block = "10.100.0.0/16"
      fw_priority    = 2000
    }
    health = {
      project_id     = var.health_project_id
      subnet_cidr    = "10.110.0.0/20"
      reserved_block = "10.110.0.0/16"
      fw_priority    = 2010
    }
  }
}

# --- Tenant VPCs (same reusable module as the shared VPC) ---------------------

module "tenant_vpc" {
  source   = "./modules/vpc"
  for_each = local.tenants

  project_id            = each.value.project_id
  network_name          = "customer-${each.key}-vpc"
  description           = "Isolated VPC for the ${each.key} tenant"
  routing_mode          = "REGIONAL"
  mtu                   = 1460 # must match the shared VPC
  delete_default_routes = true

  subnets = {
    "${each.key}-subnet" = {
      cidr        = each.value.subnet_cidr
      region      = var.primary_region
      description = "Workloads for the ${each.key} tenant"
    }
  }

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
      description = "Path for the tenant's own Cloud NAT (Phase 6); gated by firewall"
    }
  }
}

# --- Peering: both directions per tenant --------------------------------------
# A peering only becomes ACTIVE once it exists on both sides. GCP allows only
# one peering operation at a time per network, so the four peerings are chained
# with depends_on to run one after another.

resource "google_compute_network_peering" "shared_to_fintech" {
  name                 = "peer-shared-to-fintech"
  network              = module.shared_vpc.network_self_link
  peer_network         = module.tenant_vpc["fintech"].network_self_link
  export_custom_routes = false
  import_custom_routes = false
}

resource "google_compute_network_peering" "fintech_to_shared" {
  name                 = "peer-fintech-to-shared"
  network              = module.tenant_vpc["fintech"].network_self_link
  peer_network         = module.shared_vpc.network_self_link
  export_custom_routes = false
  import_custom_routes = false

  depends_on = [google_compute_network_peering.shared_to_fintech]
}

resource "google_compute_network_peering" "shared_to_health" {
  name                 = "peer-shared-to-health"
  network              = module.shared_vpc.network_self_link
  peer_network         = module.tenant_vpc["health"].network_self_link
  export_custom_routes = false
  import_custom_routes = false

  depends_on = [google_compute_network_peering.fintech_to_shared]
}

resource "google_compute_network_peering" "health_to_shared" {
  name                 = "peer-health-to-shared"
  network              = module.tenant_vpc["health"].network_self_link
  peer_network         = module.shared_vpc.network_self_link
  export_custom_routes = false
  import_custom_routes = false

  depends_on = [google_compute_network_peering.shared_to_health]
}
