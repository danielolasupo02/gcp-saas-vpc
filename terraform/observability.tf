###############################################################################
# Phase 7 — Network monitoring and logging
#
#   COLLECT   VPC flow logs on every subnet (sampling per subnet, modules/vpc)
#             firewall, Cloud NAT and DNS logs (Phases 5–6)
#   EXPORT    flow logs ──► BigQuery  network_flow_logs (30-day partitions)
#             firewall, NAT, DNS, network admin audit ──► GCS archive (Coldline 30d, delete 365d)
#   DETECT    log-based metrics: firewall_denied_count, network_manual_change
#   ALERT     NAT drops / allocation failures, firewall deny spikes,
#             changes made outside Terraform, VPN tunnel / BGP down
#   SEE       "Network Security & Health" dashboard, Flow Analyzer (Log Analytics)
###############################################################################

locals {
  # Projects that own networks, so they produce the network logs.
  # Shared VPC flow/firewall/NAT logs for prod and nonprod VMs land in the host.
  network_log_projects = {
    host    = var.host_project_id
    fintech = var.fintech_project_id
    health  = var.health_project_id
  }
}

module "logging" {
  source = "./modules/logging"

  project_id         = var.host_project_id
  location           = var.primary_region
  name_prefix        = "network"
  source_projects    = local.network_log_projects
  terraform_sa_email = var.terraform_sa_email
}

module "monitoring" {
  source = "./modules/monitoring"

  project_id           = var.host_project_id
  alert_email          = var.alert_email
  metric_types         = module.logging.metric_types
  enable_hybrid_alerts = var.enable_hybrid_vpn

  # Tenant projects must be in the metrics scope (Phase 6) for one policy to cover them.
  depends_on = [google_monitoring_monitored_project.scope]
}
