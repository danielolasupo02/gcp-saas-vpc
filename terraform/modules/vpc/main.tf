resource "google_compute_network" "this" {
  project                         = var.project_id
  name                            = var.network_name
  description                     = var.description
  auto_create_subnetworks         = false
  routing_mode                    = var.routing_mode
  mtu                             = var.mtu
  delete_default_routes_on_create = var.delete_default_routes

  # Phase 8: DR guardrails, checked at plan time before anything is changed.
  lifecycle {
    precondition {
      condition     = length(setsubtract(toset(var.required_regions), toset([for s in var.subnets : s.region]))) == 0
      error_message = "Network ${var.network_name} must have at least one subnet in every required region (${join(", ", var.required_regions)}). A DR region with no subnets cannot take over."
    }
    precondition {
      condition     = length(distinct([for s in var.subnets : s.cidr])) == length(var.subnets)
      error_message = "Network ${var.network_name} has two subnets with the same CIDR."
    }
  }
}

locals {
  # Merge each subnet's overrides onto the network-wide defaults (null = keep default).
  subnet_flow_logs = {
    for name, s in var.subnets : name => {
      enabled              = coalesce(s.flow_logs.enabled, var.flow_logs.enabled)
      aggregation_interval = coalesce(s.flow_logs.aggregation_interval, var.flow_logs.aggregation_interval)
      flow_sampling        = coalesce(s.flow_logs.flow_sampling, var.flow_logs.flow_sampling)
      metadata             = coalesce(s.flow_logs.metadata, var.flow_logs.metadata)
      filter_expr          = coalesce(s.flow_logs.filter_expr, var.flow_logs.filter_expr)
    }
  }
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

  # Flow logs: network-wide defaults (var.flow_logs) with optional per-subnet
  # overrides, e.g. 100% sampling on regulated subnets, lower on dev.
  dynamic "log_config" {
    for_each = local.subnet_flow_logs[each.key].enabled ? [local.subnet_flow_logs[each.key]] : []
    content {
      aggregation_interval = log_config.value.aggregation_interval
      flow_sampling        = log_config.value.flow_sampling
      metadata             = log_config.value.metadata
      filter_expr          = log_config.value.filter_expr
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
