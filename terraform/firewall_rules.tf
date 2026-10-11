###############################################################################
# Phase 4 — Firewall rules for peered traffic
#
# GCP's implied rules already deny all ingress, so this phase only adds the
# explicit ALLOWs that peering needs. Phase 5 (security.tf) adds the logged
# deny-all rules, egress controls and isolation denies on top.
#
#   tenant  ──tcp:443──▶  shared services VMs (sa-shared-svc)   [shared VPC]
#   shared-svc-subnet ──tcp:443──▶ tenant VMs (callbacks)        [tenant VPCs]
#   IAP (35.235.240.0/20) ──tcp:22──▶ all VMs (admin access)     [all VPCs]
###############################################################################

locals {
  # Shared services VMs run as this service account (created by
  # scripts/04-peering-prereqs.sh). Rules target the identity, not a tag.
  shared_svc_sa = "sa-shared-svc@${var.host_project_id}.iam.gserviceaccount.com"

  iap_range = "35.235.240.0/20"
}

# --- Shared VPC -----------------------------------------------------------------

resource "google_compute_firewall" "shared_allow_iap_ssh" {
  project       = var.host_project_id
  name          = "allow-iap-ssh"
  description   = "Admin SSH only via Identity-Aware Proxy TCP forwarding"
  network       = module.shared_vpc.network_self_link
  direction     = "INGRESS"
  priority      = 100
  source_ranges = [local.iap_range]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# One rule per tenant, so each tenant's access can be audited and revoked alone.
resource "google_compute_firewall" "shared_allow_tenant_to_shared_svc" {
  for_each = local.tenants

  project                 = var.host_project_id
  name                    = "allow-${each.key}-to-shared-svc"
  description             = "${each.key} tenant may call shared services on HTTPS only"
  network                 = module.shared_vpc.network_self_link
  direction               = "INGRESS"
  priority                = each.value.fw_priority
  source_ranges           = [each.value.reserved_block]
  target_service_accounts = [local.shared_svc_sa]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# --- Tenant VPCs ----------------------------------------------------------------

resource "google_compute_firewall" "tenant_allow_iap_ssh" {
  for_each = local.tenants

  project       = each.value.project_id
  name          = "allow-iap-ssh"
  description   = "Admin SSH only via Identity-Aware Proxy TCP forwarding"
  network       = module.tenant_vpc[each.key].network_self_link
  direction     = "INGRESS"
  priority      = 100
  source_ranges = [local.iap_range]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "tenant_allow_shared_svc_callbacks" {
  for_each = local.tenants

  project       = each.value.project_id
  name          = "allow-shared-svc-callbacks"
  description   = "Shared services may call back into the tenant on HTTPS only"
  network       = module.tenant_vpc[each.key].network_self_link
  direction     = "INGRESS"
  priority      = 2000
  source_ranges = [local.shared_subnets["shared-svc-subnet"].cidr]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
