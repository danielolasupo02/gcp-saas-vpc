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
