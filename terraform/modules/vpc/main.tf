resource "google_compute_network" "this" {
  project                         = var.project_id
  name                            = var.network_name
  description                     = var.description
  auto_create_subnetworks         = false
  routing_mode                    = var.routing_mode
  mtu                             = var.mtu
  delete_default_routes_on_create = var.delete_default_routes
}

resource "google_compute_subnetwork" "this" {
  for_each = var.subnets

  project                  = var.project_id
  name                     = each.key
  description              = each.value.description
  network                  = google_compute_network.this.id
  region                   = each.value.region
  ip_cidr_range            = each.value.cidr
  private_ip_google_access = true

  dynamic "log_config" {
    for_each = var.flow_logs.enabled ? [1] : []
    content {
      aggregation_interval = var.flow_logs.aggregation_interval
      flow_sampling        = var.flow_logs.flow_sampling
      metadata             = var.flow_logs.metadata
    }
  }
}

resource "google_compute_route" "this" {
  for_each = var.routes

  project          = var.project_id
  name             = each.key
  description      = each.value.description
  network          = google_compute_network.this.name
  dest_range       = each.value.dest_range
  next_hop_gateway = each.value.next_hop_gateway
  priority         = each.value.priority
  tags             = each.value.tags
}
