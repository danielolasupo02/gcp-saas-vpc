output "notification_channel" {
  description = "Email notification channel ID."
  value       = google_monitoring_notification_channel.email.id
}

output "alert_policies" {
  description = "Alert policy display names."
  value = concat(
    [
      google_monitoring_alert_policy.nat_dropped.display_name,
      google_monitoring_alert_policy.nat_allocation_failed.display_name,
      google_monitoring_alert_policy.firewall_deny_spike.display_name,
      google_monitoring_alert_policy.manual_change.display_name,
    ],
    google_monitoring_alert_policy.vpn_tunnel_down[*].display_name,
    google_monitoring_alert_policy.bgp_down[*].display_name,
  )
}

output "dashboard_id" {
  description = "Network Security & Health dashboard ID."
  value       = google_monitoring_dashboard.network.id
}
