output "shared_vpc_network" {
  description = "Shared VPC network self link."
  value       = module.shared_vpc.network_self_link
}

output "shared_vpc_subnets" {
  description = "Shared VPC subnets (CIDR and region)."
  value       = { for name, s in module.shared_vpc.subnets : name => "${s.cidr} (${s.region})" }
}

output "custom_routes" {
  description = "Custom static routes in the shared VPC."
  value       = module.shared_vpc.routes
}

output "service_projects" {
  description = "Service projects attached to the Shared VPC host."
  value       = [for s in google_compute_shared_vpc_service_project.service : s.service_project]
}

output "bgp_router" {
  description = "Cloud Router used for BGP."
  value       = "${google_compute_router.bgp.name} (ASN ${var.bgp_asn})"
}

output "tenant_networks" {
  description = "Tenant VPCs and their subnets."
  value = {
    for tenant, vpc in module.tenant_vpc : tenant => {
      network = vpc.network_name
      subnets = { for name, s in vpc.subnets : name => "${s.cidr} (${s.region})" }
    }
  }
}

output "peering_states" {
  description = "State of each peering connection (ACTIVE when both sides exist)."
  value = {
    (google_compute_network_peering.shared_to_fintech.name) = google_compute_network_peering.shared_to_fintech.state
    (google_compute_network_peering.fintech_to_shared.name) = google_compute_network_peering.fintech_to_shared.state
    (google_compute_network_peering.shared_to_health.name)  = google_compute_network_peering.shared_to_health.state
    (google_compute_network_peering.health_to_shared.name)  = google_compute_network_peering.health_to_shared.state
  }
}

output "org_firewall_policy" {
  description = "Hierarchical firewall policy attached to the organization."
  value       = google_compute_firewall_policy.org_baseline.short_name
}

output "org_policies_enforced" {
  description = "Organization policy constraints enforced by Terraform."
  value = concat(
    [for c, _ in google_org_policy_policy.boolean : c],
    [google_org_policy_policy.no_external_ip.name, google_org_policy_policy.restrict_peering.name]
  )
}

output "private_dns_zones" {
  description = "Private DNS zones and the networks that can see them."
  value = {
    (google_dns_managed_zone.private_googleapis.dns_name) = "Private Google Access VIP"
    (google_dns_managed_zone.internal.dns_name)           = "Internal service names"
  }
}

output "shared_api_ip" {
  description = "Reserved internal IP behind api.saas.internal."
  value       = google_compute_address.shared_api.address
}

output "nat_gateways" {
  description = "Cloud NAT gateways: region and static egress IPs."
  value = {
    for name, g in module.egress : name => {
      region = g.region
      nat    = g.nat_name
      ips    = g.nat_ips
    }
  }
}

output "hybrid_vpn" {
  description = "HA VPN tunnels and BGP sessions to the simulated on-prem network."
  value = var.enable_hybrid_vpn ? {
    tunnels   = concat([for t in google_compute_vpn_tunnel.shared_to_onprem : t.name], [for t in google_compute_vpn_tunnel.onprem_to_shared : t.name])
    bgp_peers = concat([for p in google_compute_router_peer.shared : p.name], [for p in google_compute_router_peer.onprem : p.name])
    on_prem   = "${module.onprem_vpc.subnets["onprem-subnet"].cidr} (ASN ${var.onprem_bgp_asn})"
  } : null
}

output "egress_dashboard" {
  description = "Cloud Monitoring dashboard for NAT, VPN and BGP."
  value       = "https://console.cloud.google.com/monitoring/dashboards?project=${var.host_project_id}"
}

output "flow_log_sampling" {
  description = "Effective flow log sampling per subnet."
  value = merge(
    { for s, c in module.shared_vpc.flow_logs : s => c.flow_sampling },
    { for t, v in module.tenant_vpc : "${t}-subnet" => v.flow_logs["${t}-subnet"].flow_sampling },
  )
}

output "log_exports" {
  description = "Where network logs are exported."
  value = {
    flow_logs_bigquery = module.logging.flow_dataset
    audit_archive_gcs  = module.logging.archive_bucket
  }
}

output "alert_policies" {
  description = "Network alert policies."
  value       = module.monitoring.alert_policies
}
