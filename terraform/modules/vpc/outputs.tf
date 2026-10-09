output "network_id" {
  description = "Network ID."
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "Network name."
  value       = google_compute_network.this.name
}

output "network_self_link" {
  description = "Network self link (used for peering)."
  value       = google_compute_network.this.self_link
}

output "subnets" {
  description = "Subnets keyed by name."
  value = {
    for name, s in google_compute_subnetwork.this : name => {
      id        = s.id
      self_link = s.self_link
      cidr      = s.ip_cidr_range
      region    = s.region
    }
  }
}

output "routes" {
  description = "Custom route names."
  value       = [for r in google_compute_route.this : r.name]
}
