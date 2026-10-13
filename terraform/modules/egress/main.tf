###############################################################################
# Egress module — Cloud Router + Cloud NAT with reserved static IPs
#
# One instance = one regional egress gateway for one set of subnets.
#   - Static IPs: a stable, known source address that partners can allowlist
#   - Two+ IPs: if one IP is drained or exhausted, new connections use the other
#   - Dynamic port allocation: busy VMs grow from 64 up to 4096 ports instead of
#     failing, quiet VMs keep few ports, so IPs aren't exhausted by idle VMs
#   - Logging: errors (and optionally translations) go to Cloud Logging
###############################################################################

resource "google_compute_address" "nat" {
  count = var.nat_ip_count

  project      = var.project_id
  name         = "nat-${var.name}-ip-${count.index}"
  description  = "Static egress IP ${count.index} for ${var.name}"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
}

resource "google_compute_router" "nat" {
  project     = var.project_id
  name        = "nat-router-${var.name}"
  description = "Cloud Router hosting the ${var.name} NAT gateway"
  region      = var.region
  network     = var.network
}

resource "google_compute_router_nat" "this" {
  project = var.project_id
  name    = "nat-${var.name}"
  router  = google_compute_router.nat.name
  region  = var.region

  # Use only our reserved IPs — never let Google pick random ones.
  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = google_compute_address.nat[*].self_link

  source_subnetwork_ip_ranges_to_nat = length(var.subnetworks) == 0 ? "ALL_SUBNETWORKS_ALL_IP_RANGES" : "LIST_OF_SUBNETWORKS"

  dynamic "subnetwork" {
    for_each = var.subnetworks
    content {
      name                    = subnetwork.value
      source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
    }
  }

  # Dynamic port allocation (requires endpoint-independent mapping off)
  enable_dynamic_port_allocation      = true
  enable_endpoint_independent_mapping = false
  min_ports_per_vm                    = var.min_ports_per_vm
  max_ports_per_vm                    = var.max_ports_per_vm

  log_config {
    enable = true
    filter = var.log_filter
  }
}
