output "archive_bucket" {
  description = "GCS bucket holding firewall, NAT, DNS and network admin logs."
  value       = google_storage_bucket.archive.name
}

output "flow_dataset" {
  description = "BigQuery dataset holding VPC flow logs."
  value       = "${var.project_id}.${google_bigquery_dataset.flows.dataset_id}"
}

output "sinks" {
  description = "Sinks created per source project."
  value = {
    for k, p in var.source_projects : k => {
      project = p
      flows   = google_logging_project_sink.flows[k].name
      audit   = google_logging_project_sink.audit[k].name
    }
  }
}

# Referencing the metric resources makes anything that uses these outputs
# (alert policies) wait until the metrics exist.
output "metric_types" {
  description = "Monitoring metric types of the log-based metrics."
  value = {
    firewall_denied = "logging.googleapis.com/user/${values(google_logging_metric.firewall_denied)[0].name}"
    manual_change   = "logging.googleapis.com/user/${values(google_logging_metric.manual_change)[0].name}"
  }
}
