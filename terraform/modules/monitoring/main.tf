###############################################################################
# Monitoring module: alert policies + network security dashboard
#
#   Alert                      Signal                                     Fires when
#   NAT packets dropped        router.googleapis.com/nat/dropped_sent_*   > 0 for 5 min
#   NAT allocation failed      router.googleapis.com/nat/nat_allocation_* any failure (port exhaustion)
#   Firewall deny spike        log metric firewall_denied_count           > threshold / 5 min
#   Manual network change      log metric network_manual_change           any change not made by Terraform
#   HA VPN tunnel down         vpn.googleapis.com/tunnel_established      < 1 for 5 min   (hybrid only)
#   BGP session down           router.googleapis.com/bgp/session_up       < 1 for 5 min   (hybrid only)
#
# Alert filters on log-based metrics must name a resource.type. Firewall logs
# keep gce_subnetwork (verified via the timeSeries API). Firewall-rule/route
# audit logs map to "global"; router and VPN changes keep their own types.
#
# Policies live in the metrics-scope project, so one policy covers the host,
# service and tenant projects.
###############################################################################

locals {
  hybrid = var.enable_hybrid_alerts ? 1 : 0

  # Dashboard tiles. Same JSON shape the Monitoring API stores (Phase 6 lesson):
  # targetAxis set, xPos/yPos omitted when 0, otherwise every plan shows a diff.
  tiles = [
    { title = "Firewall denies by rule (all projects)", filter = "metric.type=\"${var.metric_types.firewall_denied}\"", aligner = "ALIGN_SUM", group_by = ["metric.label.rule"] },
    { title = "Manual network changes (should be 0)", filter = "metric.type=\"${var.metric_types.manual_change}\"", aligner = "ALIGN_SUM", group_by = ["metric.label.principal"] },
    { title = "NAT dropped sent packets/s", filter = "metric.type=\"router.googleapis.com/nat/dropped_sent_packets_count\" resource.type=\"nat_gateway\"", aligner = "ALIGN_RATE", group_by = ["resource.label.gateway_name"] },
    { title = "NAT allocation failures", filter = "metric.type=\"router.googleapis.com/nat/nat_allocation_failed\" resource.type=\"nat_gateway\"", aligner = "ALIGN_COUNT_TRUE", group_by = ["resource.label.gateway_name"] },
    { title = "HA VPN tunnel established (1 = up)", filter = "metric.type=\"vpn.googleapis.com/tunnel_established\" resource.type=\"vpn_gateway\"", aligner = "ALIGN_MEAN", group_by = ["metric.label.tunnel_name"] },
    { title = "BGP session up (1 = up)", filter = "metric.type=\"router.googleapis.com/bgp/session_up\" resource.type=\"gce_router\"", aligner = "ALIGN_FRACTION_TRUE", group_by = ["metric.label.bgp_peer_name"] },
  ]
}

resource "google_monitoring_notification_channel" "email" {
  project      = var.project_id
  display_name = "Network on-call (email)"
  type         = "email"

  labels = {
    email_address = var.alert_email
  }
}

# --- Cloud NAT ------------------------------------------------------------------

resource "google_monitoring_alert_policy" "nat_dropped" {
  project               = var.project_id
  display_name          = "NAT: packets dropped"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "dropped_sent_packets > 0 for 5 min"
    condition_threshold {
      filter          = "metric.type=\"router.googleapis.com/nat/dropped_sent_packets_count\" resource.type=\"nat_gateway\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "A NAT gateway is dropping outbound packets. Check `nat_allocation_failed` and port usage; raise `max_ports_per_vm` or add a NAT IP in `egress.tf`."
  }
}

resource "google_monitoring_alert_policy" "nat_allocation_failed" {
  project               = var.project_id
  display_name          = "NAT: port allocation failed"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "nat_allocation_failed is true"
    condition_threshold {
      filter          = "metric.type=\"router.googleapis.com/nat/nat_allocation_failed\" resource.type=\"nat_gateway\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_COUNT_TRUE"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "VMs behind a NAT gateway could not get source ports (port exhaustion). Add a static IP to the gateway's `ip_count` or raise `max_ports_per_vm`."
  }
}

# --- Security signals from log-based metrics -------------------------------------

resource "google_monitoring_alert_policy" "firewall_deny_spike" {
  project               = var.project_id
  display_name          = "Firewall: denied connections spike"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "> ${var.firewall_deny_threshold} denies in 5 min (all projects)"
    condition_threshold {
      filter          = "metric.type=\"${var.metric_types.firewall_denied}\" resource.type=\"gce_subnetwork\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.firewall_deny_threshold
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Many connections were denied in 5 minutes. Open the dashboard tile **Firewall denies by rule** to see which rule, then the firewall logs for source IPs. Possible scan, misconfigured app, or lateral-movement attempt."
  }
}

resource "google_monitoring_alert_policy" "manual_change" {
  project               = var.project_id
  display_name          = "Network: change made outside Terraform"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "any network change by a non-Terraform identity"
    condition_threshold {
      filter          = "metric.type=\"${var.metric_types.manual_change}\" resource.type=one_of(\"global\", \"gce_router\", \"vpn_gateway\")"
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.principal", "metric.label.method"]
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "Someone changed network config directly. Run `terraform plan` to see the drift, confirm whether it was an approved break-glass change, then `terraform apply` to restore (or codify the change)."
  }
}

# --- Hybrid connectivity (only while the HA VPN exists) ---------------------------

resource "google_monitoring_alert_policy" "vpn_tunnel_down" {
  count = local.hybrid

  project               = var.project_id
  display_name          = "HA VPN: tunnel down"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "tunnel_established < 1 for 5 min"
    condition_threshold {
      filter          = "metric.type=\"vpn.googleapis.com/tunnel_established\" resource.type=\"vpn_gateway\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "An HA VPN tunnel is down. Traffic fails over to the other tunnel; check the peer gateway and tunnel logs before the second one fails."
  }
}

resource "google_monitoring_alert_policy" "bgp_down" {
  count = local.hybrid

  project               = var.project_id
  display_name          = "BGP: session down"
  combiner              = "OR"
  notification_channels = [google_monitoring_notification_channel.email.id]

  conditions {
    display_name = "session_up < 1 for 5 min"
    condition_threshold {
      filter          = "metric.type=\"router.googleapis.com/bgp/session_up\" resource.type=\"gce_router\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_FRACTION_TRUE"
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "A BGP session is down, so routes from that tunnel are withdrawn. Check `gcloud compute routers get-status` for the peer state."
  }
}

# --- Dashboard --------------------------------------------------------------------

resource "google_monitoring_dashboard" "network" {
  project = var.project_id

  dashboard_json = jsonencode({
    displayName = "Network Security & Health"
    mosaicLayout = {
      columns = 12
      tiles = [
        for i, t in local.tiles : merge(
          { for k, v in { xPos = (i % 2) * 6, yPos = floor(i / 2) * 4 } : k => v if v != 0 },
          {
            width  = 6
            height = 4
            widget = {
              title = t.title
              xyChart = {
                dataSets = [{
                  plotType   = "LINE"
                  targetAxis = "Y1"
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = t.filter
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = t.aligner
                        crossSeriesReducer = "REDUCE_SUM"
                        groupByFields      = t.group_by
                      }
                    }
                  }
                }]
              }
            }
          }
        )
      ]
    }
  })
}
