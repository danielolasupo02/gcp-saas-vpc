###############################################################################
# Phase 6 — Egress management and hybrid connectivity
#
#   INTERNET EGRESS (Cloud NAT, one gateway per environment/tenant per region)
#     prod-subnet           → nat-shared-central-prod     (2 static IPs)
#     dev/staging/shared    → nat-shared-central-nonprod  (1 static IP)
#     prod-subnet-east      → nat-shared-east-prod        (1 static IP)
#     customer-fintech-vpc  → nat-fintech                 (1 static IP)
#     customer-health-vpc   → nat-health                  (1 static IP)
#
#   Egress routing policy = route + NAT mapping + firewall:
#     0.0.0.0/0 route (Phase 3/4) → NAT gateway chosen by SUBNET →
#     allowed only for tcp:443 by service account (Phase 5, priority 4100)
#
#   HYBRID (simulated on-prem over HA VPN + BGP)
#     shared-vpc-network (ASN 64512) ⇄ 2 tunnels ⇄ onprem-sim-vpc (ASN 64513)
#     On-prem learns only 10.0.0.0/20; the shared VPC learns 192.168.0.0/20.
#     Set enable_hybrid_vpn = false to remove the VPN (tunnels cost ~$0.05/h each).
###############################################################################

# =============================================================================
# 1. CLOUD NAT
# =============================================================================

locals {
  shared_subnet_links = { for name, s in module.shared_vpc.subnets : name => s.self_link }

  nat_gateways = {
    "shared-central-prod" = {
      project     = var.host_project_id
      network     = module.shared_vpc.network_self_link
      region      = var.primary_region
      subnetworks = [local.shared_subnet_links["prod-subnet"]]
      ip_count    = 2 # two IPs: drain one, the other keeps prod online
      log_filter  = "ALL"
    }
    "shared-central-nonprod" = {
      project = var.host_project_id
      network = module.shared_vpc.network_self_link
      region  = var.primary_region
      subnetworks = [
        local.shared_subnet_links["dev-subnet"],
        local.shared_subnet_links["staging-subnet"],
        local.shared_subnet_links["shared-svc-subnet"],
      ]
      ip_count   = 1
      log_filter = "ALL"
    }
    "shared-east-prod" = {
      project     = var.host_project_id
      network     = module.shared_vpc.network_self_link
      region      = var.secondary_region
      subnetworks = [local.shared_subnet_links["prod-subnet-east"]]
      ip_count    = 1 # regional failover: prod in us-east1 has its own gateway
      log_filter  = "ALL"
    }
    "fintech" = {
      project     = var.fintech_project_id
      network     = module.tenant_vpc["fintech"].network_self_link
      region      = var.primary_region
      subnetworks = [] # all subnets in the tenant VPC
      ip_count    = 1
      log_filter  = "ERRORS_ONLY"
    }
    "health" = {
      project     = var.health_project_id
      network     = module.tenant_vpc["health"].network_self_link
      region      = var.primary_region
      subnetworks = []
      ip_count    = 1
      log_filter  = "ERRORS_ONLY"
    }
  }
}

module "egress" {
  source   = "./modules/egress"
  for_each = local.nat_gateways

  project_id   = each.value.project
  name         = each.key
  region       = each.value.region
  network      = each.value.network
  subnetworks  = each.value.subnetworks
  nat_ip_count = each.value.ip_count
  log_filter   = each.value.log_filter
}

# =============================================================================
# 2. SIMULATED ON-PREMISES NETWORK
# =============================================================================

module "onprem_vpc" {
  source = "./modules/vpc"

  project_id            = var.host_project_id
  network_name          = "onprem-sim-vpc"
  description           = "Simulated on-premises data centre (reached only over HA VPN)"
  routing_mode          = "REGIONAL"
  mtu                   = 1460
  delete_default_routes = true

  subnets = {
    "onprem-subnet" = {
      cidr        = "192.168.0.0/20"
      region      = var.primary_region
      description = "Simulated on-prem servers"
    }
  }

  # Needed only so IAP's replies (35.235.240.0/20) have a return path for admin SSH.
  routes = {
    "onprem-default-egress" = {
      dest_range  = "0.0.0.0/0"
      priority    = 1000
      description = "Return path for IAP admin access"
    }
  }
}

resource "google_compute_firewall" "onprem_allow_iap_ssh" {
  project       = var.host_project_id
  name          = "onprem-allow-iap-ssh"
  description   = "Admin SSH into the simulated on-prem VMs via IAP"
  network       = module.onprem_vpc.network_self_link
  direction     = "INGRESS"
  priority      = 100
  source_ranges = [local.iap_range]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_router" "onprem" {
  project     = var.host_project_id
  name        = "onprem-router"
  description = "On-prem side BGP speaker"
  region      = var.primary_region
  network     = module.onprem_vpc.network_self_link

  bgp {
    asn            = var.onprem_bgp_asn
    advertise_mode = "DEFAULT" # advertises 192.168.0.0/20
  }
}

# Shared VPC: on-prem may call shared services on HTTPS (hybrid band 3000-3999)
resource "google_compute_firewall" "shared_allow_onprem_to_shared_svc" {
  project                 = var.host_project_id
  name                    = "allow-onprem-to-shared-svc"
  description             = "On-prem may call shared services on HTTPS only"
  network                 = module.shared_vpc.network_self_link
  direction               = "INGRESS"
  priority                = 3000
  source_ranges           = [module.onprem_vpc.subnets["onprem-subnet"].cidr]
  target_service_accounts = [local.shared_svc_sa]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# =============================================================================
# 3. HA VPN + BGP (toggle with enable_hybrid_vpn)
# =============================================================================

locals {
  vpn_tunnel_defs = {
    "0" = { shared_ip = "169.254.0.1", onprem_ip = "169.254.0.2" }
    "1" = { shared_ip = "169.254.1.1", onprem_ip = "169.254.1.2" }
  }
  vpn_tunnels = { for k, v in local.vpn_tunnel_defs : k => v if var.enable_hybrid_vpn }
  vpn_count   = var.enable_hybrid_vpn ? 1 : 0
}

resource "google_compute_ha_vpn_gateway" "shared" {
  count   = local.vpn_count
  project = var.host_project_id
  name    = "ha-vpn-shared"
  region  = var.primary_region
  network = module.shared_vpc.network_self_link
}

resource "google_compute_ha_vpn_gateway" "onprem" {
  count   = local.vpn_count
  project = var.host_project_id
  name    = "ha-vpn-onprem"
  region  = var.primary_region
  network = module.onprem_vpc.network_self_link
}

resource "random_password" "vpn_psk" {
  count   = local.vpn_count
  length  = 32
  special = false
}

resource "google_compute_vpn_tunnel" "shared_to_onprem" {
  for_each = local.vpn_tunnels

  project               = var.host_project_id
  name                  = "tunnel-shared-to-onprem-${each.key}"
  region                = var.primary_region
  vpn_gateway           = google_compute_ha_vpn_gateway.shared[0].id
  vpn_gateway_interface = tonumber(each.key)
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.onprem[0].id
  shared_secret         = random_password.vpn_psk[0].result
  router                = google_compute_router.bgp.id
}

resource "google_compute_vpn_tunnel" "onprem_to_shared" {
  for_each = local.vpn_tunnels

  project               = var.host_project_id
  name                  = "tunnel-onprem-to-shared-${each.key}"
  region                = var.primary_region
  vpn_gateway           = google_compute_ha_vpn_gateway.onprem[0].id
  vpn_gateway_interface = tonumber(each.key)
  peer_gcp_gateway      = google_compute_ha_vpn_gateway.shared[0].id
  shared_secret         = random_password.vpn_psk[0].result
  router                = google_compute_router.onprem.id
}

resource "google_compute_router_interface" "shared" {
  for_each = local.vpn_tunnels

  project    = var.host_project_id
  name       = "if-shared-to-onprem-${each.key}"
  router     = google_compute_router.bgp.name
  region     = var.primary_region
  ip_range   = "${each.value.shared_ip}/30"
  vpn_tunnel = google_compute_vpn_tunnel.shared_to_onprem[each.key].name
}

resource "google_compute_router_peer" "shared" {
  for_each = local.vpn_tunnels

  project                   = var.host_project_id
  name                      = "bgp-shared-to-onprem-${each.key}"
  router                    = google_compute_router.bgp.name
  region                    = var.primary_region
  peer_ip_address           = each.value.onprem_ip
  peer_asn                  = var.onprem_bgp_asn
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.shared[each.key].name
}

resource "google_compute_router_interface" "onprem" {
  for_each = local.vpn_tunnels

  project    = var.host_project_id
  name       = "if-onprem-to-shared-${each.key}"
  router     = google_compute_router.onprem.name
  region     = var.primary_region
  ip_range   = "${each.value.onprem_ip}/30"
  vpn_tunnel = google_compute_vpn_tunnel.onprem_to_shared[each.key].name
}

resource "google_compute_router_peer" "onprem" {
  for_each = local.vpn_tunnels

  project                   = var.host_project_id
  name                      = "bgp-onprem-to-shared-${each.key}"
  router                    = google_compute_router.onprem.name
  region                    = var.primary_region
  peer_ip_address           = each.value.shared_ip
  peer_asn                  = var.bgp_asn
  advertised_route_priority = 100
  interface                 = google_compute_router_interface.onprem[each.key].name
}

# =============================================================================
# 4. NAT / VPN MONITORING DASHBOARD
# =============================================================================

# One metrics scope: the host project can chart metrics from every project.
resource "google_monitoring_monitored_project" "scope" {
  for_each = toset([
    var.prod_service_project_id,
    var.nonprod_service_project_id,
    var.fintech_project_id,
    var.health_project_id,
  ])

  metrics_scope = "locations/global/metricsScopes/${var.host_project_id}"
  name          = each.value
}

locals {
  dashboard_tiles = [
    { title = "NAT allocated ports per gateway", metric = "router.googleapis.com/nat/allocated_ports", resource = "nat_gateway", aligner = "ALIGN_MEAN" },
    { title = "NAT open connections", metric = "router.googleapis.com/nat/open_connections", resource = "nat_gateway", aligner = "ALIGN_MEAN" },
    { title = "NAT sent bytes/s", metric = "router.googleapis.com/nat/sent_bytes_count", resource = "nat_gateway", aligner = "ALIGN_RATE" },
    { title = "NAT dropped sent packets/s (should be 0)", metric = "router.googleapis.com/nat/dropped_sent_packets_count", resource = "nat_gateway", aligner = "ALIGN_RATE" },
    { title = "HA VPN tunnel established (1 = up)", metric = "vpn.googleapis.com/tunnel_established", resource = "vpn_gateway", aligner = "ALIGN_MEAN" },
    { title = "BGP session up (1 = up)", metric = "router.googleapis.com/bgp/session_up", resource = "gce_router", aligner = "ALIGN_FRACTION_TRUE" },
  ]
}

resource "google_monitoring_dashboard" "egress" {
  project = var.host_project_id

  dashboard_json = jsonencode({
    displayName = "Egress & Hybrid Connectivity (Cloud NAT, HA VPN, BGP)"
    mosaicLayout = {
      columns = 12
      # The API drops xPos/yPos when they are 0 and adds targetAxis = "Y1".
      # Match that shape exactly, otherwise every plan shows a false diff.
      tiles = [
        for i, t in local.dashboard_tiles : merge(
          { for k, v in { xPos = (i % 2) * 6, yPos = floor(i / 2) * 4 } : k => v if v != 0 },
          {
            width  = 6
            height = 4
            widget = {
              title = t.title
              xyChart = {
                dataSets = [{
                  plotType   = "LINE"
                  targetAxis = "Y1"
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = "metric.type=\"${t.metric}\" resource.type=\"${t.resource}\""
                      aggregation = {
                        alignmentPeriod  = "60s"
                        perSeriesAligner = t.aligner
                      }
                    }
                  }
                }]
              }
            }
          }
        )
      ]
    }
  })

  depends_on = [google_monitoring_monitored_project.scope]
}
