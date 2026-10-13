output "router_name" {
  description = "Cloud Router hosting the NAT."
  value       = google_compute_router.nat.name
}

output "nat_name" {
  description = "Cloud NAT gateway name."
  value       = google_compute_router_nat.this.name
}

output "nat_ips" {
  description = "Reserved static egress IPs."
  value       = google_compute_address.nat[*].address
}

output "nat_ip_names" {
  description = "Names of the reserved IP resources (used for failover tests)."
  value       = google_compute_address.nat[*].name
}

output "region" {
  description = "Region of the gateway."
  value       = var.region
}
