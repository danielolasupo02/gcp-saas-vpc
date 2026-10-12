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
