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
