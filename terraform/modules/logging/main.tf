###############################################################################
# Logging module: central export of network logs + log-based metrics
#
#   source projects ─┬─ sink: VPC flow logs ──────────────► BigQuery (analytics, 30d)
#                    └─ sink: firewall, NAT, DNS, network ─► GCS archive (Coldline, 365d)
#                         admin audit logs
#
#   Log-based metrics in every source project (same name, so one alert in the
#   metrics scope covers all of them):
#     firewall_denied_count  - DENIED firewall connections, labelled by rule
#     network_manual_change  - network changes made by anyone except Terraform
###############################################################################

locals {
  flow_log_filter = "log_id(\"compute.googleapis.com/vpc_flows\")"

  # Everything an auditor asks for after an incident.
  audit_log_filter = join(" OR ", [
    "log_id(\"compute.googleapis.com/firewall\")",
    "log_id(\"compute.googleapis.com/nat_flows\")",
    "log_id(\"dns.googleapis.com/dns_queries\")",
    "(log_id(\"cloudaudit.googleapis.com/activity\") AND protoPayload.serviceName=\"compute.googleapis.com\")",
  ])

  # [.] instead of \. avoids double escaping (HCL string inside an LQL string).
  network_methods = "[.](firewalls|routes|routers|networks|subnetworks|vpnTunnels|vpnGateways|addresses|firewallPolicies)[.](insert|patch|update|delete|addRule|patchRule|removeRule)$"
}

# --- Destinations (central project) ------------------------------------------

resource "google_storage_bucket" "archive" {
  project                     = var.project_id
  name                        = "${var.project_id}-${var.name_prefix}-log-archive"
  location                    = var.location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy

  lifecycle_rule {
    condition {
      age = var.archive_coldline_after_days
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  lifecycle_rule {
    condition {
      age = var.archive_delete_after_days
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    purpose = "network-log-archive"
  }
}

resource "google_bigquery_dataset" "flows" {
  project                         = var.project_id
  dataset_id                      = "${replace(var.name_prefix, "-", "_")}_flow_logs"
  friendly_name                   = "VPC flow logs"
  description                     = "VPC flow logs from all network projects, partitioned by day."
  location                        = var.location
  default_partition_expiration_ms = var.flow_log_table_expiration_days * 24 * 60 * 60 * 1000
  delete_contents_on_destroy      = var.force_destroy

  labels = {
    purpose = "network-flow-analytics"
  }
}

# --- Sinks (one pair per source project) -------------------------------------

resource "google_logging_project_sink" "flows" {
  for_each = var.source_projects

  project                = each.value
  name                   = "${var.name_prefix}-flows-to-bq"
  description            = "VPC flow logs to BigQuery for analytics"
  destination            = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.flows.dataset_id}"
  filter                 = local.flow_log_filter
  unique_writer_identity = true

  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_logging_project_sink" "audit" {
  for_each = var.source_projects

  project                = each.value
  name                   = "${var.name_prefix}-audit-to-gcs"
  description            = "Firewall, NAT, DNS and network admin logs to the long-term archive"
  destination            = "storage.googleapis.com/${google_storage_bucket.archive.name}"
  filter                 = local.audit_log_filter
  unique_writer_identity = true
}

# Each sink writes with its own identity; grant it only its destination.
resource "google_bigquery_dataset_iam_member" "flows_writer" {
  for_each = var.source_projects

  project    = var.project_id
  dataset_id = google_bigquery_dataset.flows.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.flows[each.key].writer_identity
}

resource "google_storage_bucket_iam_member" "audit_writer" {
  for_each = var.source_projects

  bucket = google_storage_bucket.archive.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.audit[each.key].writer_identity
}

# --- Log Analytics on the central _Default bucket (enables Flow Analyzer) -----

resource "google_logging_project_bucket_config" "default" {
  count = var.enable_log_analytics ? 1 : 0

  project          = var.project_id
  location         = "global"
  bucket_id        = "_Default"
  retention_days   = 30
  enable_analytics = true
}

# --- Log-based metrics ---------------------------------------------------------

resource "google_logging_metric" "firewall_denied" {
  for_each = var.source_projects

  project     = each.value
  name        = "firewall_denied_count"
  description = "Connections denied by VPC or hierarchical firewall rules."
  filter      = "log_id(\"compute.googleapis.com/firewall\") AND jsonPayload.disposition=\"DENIED\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "rule"
      value_type  = "STRING"
      description = "Firewall rule that denied the connection"
    }
  }

  label_extractors = {
    rule = "EXTRACT(jsonPayload.rule_details.reference)"
  }
}

resource "google_logging_metric" "manual_change" {
  for_each = var.source_projects

  project     = each.value
  name        = "network_manual_change"
  description = "Network configuration changed by an identity other than Terraform (drift risk)."
  filter = join(" AND ", [
    "log_id(\"cloudaudit.googleapis.com/activity\")",
    "protoPayload.serviceName=\"compute.googleapis.com\"",
    "protoPayload.methodName=~\"${local.network_methods}\"",
    "operation.first=true",
    "protoPayload.authenticationInfo.principalEmail!=\"${var.terraform_sa_email}\"",
  ])

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "principal"
      value_type  = "STRING"
      description = "Who made the change"
    }
    labels {
      key         = "method"
      value_type  = "STRING"
      description = "API method called"
    }
  }

  label_extractors = {
    principal = "EXTRACT(protoPayload.authenticationInfo.principalEmail)"
    method    = "EXTRACT(protoPayload.methodName)"
  }
}
