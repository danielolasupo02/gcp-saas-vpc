###############################################################################
# Phase 5 — Security controls (zero trust)
#
#   1. Organization guardrails
#        - Hierarchical firewall policy (applies to every VPC in the org)
#        - Organization policies (no external IPs, OS Login, restricted peering…)
#   2. Shared VPC firewall: default deny both ways, isolation denies,
#      per-environment allows targeted by service account
#   3. Tenant VPC firewall: default deny both ways, egress allow-list
#   4. Secure DNS: private zones, Private Google Access via DNS, query logging
#
# Priority bands (lower number wins):
#   100-199    platform access (IAP, health checks)
#   500-999    isolation denies
#   1000-1999  environment traffic
#   2000-2999  tenant <-> shared services
#   3000-3999  hybrid / on-prem (Phase 6)
#   4000       deny egress to all private ranges not allowed above
#   4100       allow HTTPS egress to the internet (via Cloud NAT, Phase 6)
#   65000      deny all (logged)
###############################################################################

# =============================================================================
# 1. ORGANIZATION GUARDRAILS
# =============================================================================

# --- Hierarchical firewall policy --------------------------------------------
# Evaluated BEFORE any VPC firewall rule, in every VPC in the organization,
# including tenant VPCs created in the future.

resource "google_compute_firewall_policy" "org_baseline" {
  parent      = "organizations/${var.org_id}"
  short_name  = "org-baseline-policy"
  description = "Org-wide guardrails: admin access only via IAP, tenants can never reach each other"
}

resource "google_compute_firewall_policy_rule" "org_allow_iap_admin" {
  firewall_policy = google_compute_firewall_policy.org_baseline.name
  description     = "Let IAP admin traffic continue to VPC-level rules"
  priority        = 1000
  direction       = "INGRESS"
  action          = "goto_next"

  match {
    src_ip_ranges = [local.iap_range]
    layer4_configs {
      ip_protocol = "tcp"
      ports       = ["22", "3389"]
    }
  }
}

resource "google_compute_firewall_policy_rule" "org_deny_admin_ports" {
  firewall_policy = google_compute_firewall_policy.org_baseline.name
  description     = "SSH/RDP from anywhere other than IAP is denied org-wide"
  priority        = 1100
  direction       = "INGRESS"
  action          = "deny"
  enable_logging  = true

  match {
    src_ip_ranges = ["0.0.0.0/0"]
    layer4_configs {
      ip_protocol = "tcp"
      ports       = ["22", "3389"]
    }
  }
}

# Defence in depth: peering is already non-transitive, but if anyone ever
# connects the tenants another way, this still blocks it.
resource "google_compute_firewall_policy_rule" "org_deny_fintech_to_health" {
  firewall_policy = google_compute_firewall_policy.org_baseline.name
  description     = "Fintech tenant can never reach healthcare tenant"
  priority        = 1200
  direction       = "INGRESS"
  action          = "deny"
  enable_logging  = true

  match {
    src_ip_ranges  = [local.tenants.fintech.reserved_block]
    dest_ip_ranges = [local.tenants.health.reserved_block]
    layer4_configs {
      ip_protocol = "all"
    }
  }
}

resource "google_compute_firewall_policy_rule" "org_deny_health_to_fintech" {
  firewall_policy = google_compute_firewall_policy.org_baseline.name
  description     = "Healthcare tenant can never reach fintech tenant"
  priority        = 1210
  direction       = "INGRESS"
  action          = "deny"
  enable_logging  = true

  match {
    src_ip_ranges  = [local.tenants.health.reserved_block]
    dest_ip_ranges = [local.tenants.fintech.reserved_block]
    layer4_configs {
      ip_protocol = "all"
    }
  }
}

resource "google_compute_firewall_policy_association" "org" {
  firewall_policy   = google_compute_firewall_policy.org_baseline.id
  attachment_target = "organizations/${var.org_id}"
  name              = "org-baseline-association"

  depends_on = [
    google_compute_firewall_policy_rule.org_allow_iap_admin,
    google_compute_firewall_policy_rule.org_deny_admin_ports,
    google_compute_firewall_policy_rule.org_deny_fintech_to_health,
    google_compute_firewall_policy_rule.org_deny_health_to_fintech,
  ]
}

# --- Organization policies (preventive controls) ------------------------------

locals {
  boolean_org_policies = {
    "compute.requireOsLogin"               = "SSH keys tied to IAM identities, not loose metadata keys"
    "compute.skipDefaultNetworkCreation"   = "New projects never get the permissive 'default' network"
    "iam.disableServiceAccountKeyCreation" = "No long-lived service account keys; impersonation only"
  }
}

resource "google_org_policy_policy" "boolean" {
  for_each = local.boolean_org_policies

  name   = "organizations/${var.org_id}/policies/${each.key}"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "no_external_ip" {
  name   = "organizations/${var.org_id}/policies/compute.vmExternalIpAccess"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      deny_all = "TRUE"
    }
  }
}

resource "google_org_policy_policy" "restrict_peering" {
  name   = "organizations/${var.org_id}/policies/compute.restrictVpcPeering"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      values {
        allowed_values = ["under:organizations/${var.org_id}"]
      }
    }
  }
}

# =============================================================================
# 2. SHARED VPC FIREWALL
# =============================================================================

# --- Ingress ------------------------------------------------------------------

resource "google_compute_firewall" "shared_allow_health_checks" {
  project                 = var.host_project_id
  name                    = "allow-health-checks"
  description             = "Google load balancer health checks to prod and shared services"
  network                 = module.shared_vpc.network_self_link
  direction               = "INGRESS"
  priority                = 110
  source_ranges           = ["35.191.0.0/16", "130.211.0.0/22"]
  target_service_accounts = [local.environments.prod.sa, local.shared_svc_sa]

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }
}

resource "google_compute_firewall" "shared_deny_nonprod_to_prod" {
  project                 = var.host_project_id
  name                    = "deny-nonprod-to-prod"
  description             = "Dev and staging can never reach production"
  network                 = module.shared_vpc.network_self_link
  direction               = "INGRESS"
  priority                = 500
  source_ranges           = local.nonprod_cidrs
  target_service_accounts = [local.environments.prod.sa]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "shared_deny_tenants_to_envs" {
  project                 = var.host_project_id
  name                    = "deny-tenants-to-envs"
  description             = "Tenants may only reach shared services, never dev/staging/prod"
  network                 = module.shared_vpc.network_self_link
  direction               = "INGRESS"
  priority                = 510
  source_ranges           = local.tenant_cidrs
  target_service_accounts = local.env_sas

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "shared_allow_env_internal" {
  for_each = local.environments

  project                 = var.host_project_id
  name                    = "allow-${each.key}-internal"
  description             = "${each.key} workloads may talk to each other on app ports"
  network                 = module.shared_vpc.network_self_link
  direction               = "INGRESS"
  priority                = each.value.priority
  source_ranges           = [each.value.cidr_block]
  target_service_accounts = [each.value.sa]

  allow {
    protocol = "tcp"
    ports    = ["443", "8080"]
  }
}

resource "google_compute_firewall" "shared_allow_envs_to_shared_svc" {
  project                 = var.host_project_id
  name                    = "allow-envs-to-shared-svc"
  description             = "All environments may call shared services on HTTPS"
  network                 = module.shared_vpc.network_self_link
  direction               = "INGRESS"
  priority                = 1030
  source_ranges           = local.env_cidrs
  target_service_accounts = [local.shared_svc_sa]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "shared_deny_all_ingress" {
  project       = var.host_project_id
  name          = "deny-all-ingress"
  description   = "Explicit, logged default deny (the implied rule cannot be logged)"
  network       = module.shared_vpc.network_self_link
  direction     = "INGRESS"
  priority      = 65000
  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# --- Egress -------------------------------------------------------------------

resource "google_compute_firewall" "shared_allow_egress_google_apis" {
  project            = var.host_project_id
  name               = "allow-egress-google-apis"
  description        = "All VMs may reach Google APIs via private.googleapis.com"
  network            = module.shared_vpc.network_self_link
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = [local.google_apis_vip]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "shared_allow_egress_env_internal" {
  for_each = local.environments

  project                 = var.host_project_id
  name                    = "allow-egress-${each.key}-internal"
  description             = "${each.key} workloads may call each other"
  network                 = module.shared_vpc.network_self_link
  direction               = "EGRESS"
  priority                = 1010
  destination_ranges      = [each.value.cidr_block]
  target_service_accounts = [each.value.sa]

  allow {
    protocol = "tcp"
    ports    = ["443", "8080"]
  }
}

resource "google_compute_firewall" "shared_allow_egress_to_shared_svc" {
  project                 = var.host_project_id
  name                    = "allow-egress-to-shared-svc"
  description             = "Environments may call shared services"
  network                 = module.shared_vpc.network_self_link
  direction               = "EGRESS"
  priority                = 1020
  destination_ranges      = local.shared_svc_ranges
  target_service_accounts = local.env_sas

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "shared_allow_egress_svc_to_tenants" {
  project                 = var.host_project_id
  name                    = "allow-egress-shared-svc-to-tenants"
  description             = "Shared services may call back into tenants"
  network                 = module.shared_vpc.network_self_link
  direction               = "EGRESS"
  priority                = 1030
  destination_ranges      = local.tenant_cidrs
  target_service_accounts = [local.shared_svc_sa]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "shared_deny_egress_private" {
  project            = var.host_project_id
  name               = "deny-egress-private-ranges"
  description        = "Any private destination not explicitly allowed above is denied"
  network            = module.shared_vpc.network_self_link
  direction          = "EGRESS"
  priority           = 4000
  destination_ranges = local.private_ranges

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "shared_allow_egress_internet_https" {
  project                 = var.host_project_id
  name                    = "allow-egress-internet-https"
  description             = "Workloads may reach the internet on HTTPS only (via Cloud NAT)"
  network                 = module.shared_vpc.network_self_link
  direction               = "EGRESS"
  priority                = 4100
  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = concat(local.env_sas, [local.shared_svc_sa])

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "shared_deny_all_egress" {
  project            = var.host_project_id
  name               = "deny-all-egress"
  description        = "Explicit, logged default deny for outbound traffic"
  network            = module.shared_vpc.network_self_link
  direction          = "EGRESS"
  priority           = 65000
  destination_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# =============================================================================
# 3. TENANT VPC FIREWALL (same baseline for every tenant)
# =============================================================================

resource "google_compute_firewall" "tenant_allow_egress_google_apis" {
  for_each = local.tenants

  project            = each.value.project_id
  name               = "allow-egress-google-apis"
  description        = "Tenant VMs may reach Google APIs privately"
  network            = module.tenant_vpc[each.key].network_self_link
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = [local.google_apis_vip]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "tenant_allow_egress_to_shared_svc" {
  for_each = local.tenants

  project            = each.value.project_id
  name               = "allow-egress-to-shared-svc"
  description        = "The only private destination a tenant may reach"
  network            = module.tenant_vpc[each.key].network_self_link
  direction          = "EGRESS"
  priority           = 2000
  destination_ranges = local.shared_svc_ranges

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "tenant_deny_egress_private" {
  for_each = local.tenants

  project            = each.value.project_id
  name               = "deny-egress-private-ranges"
  description        = "Tenants cannot reach dev/staging/prod or any other private range"
  network            = module.tenant_vpc[each.key].network_self_link
  direction          = "EGRESS"
  priority           = 4000
  destination_ranges = local.private_ranges

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "tenant_allow_egress_internet_https" {
  for_each = local.tenants

  project            = each.value.project_id
  name               = "allow-egress-internet-https"
  description        = "Tenant HTTPS to the internet via its own Cloud NAT (Phase 6)"
  network            = module.tenant_vpc[each.key].network_self_link
  direction          = "EGRESS"
  priority           = 4100
  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "tenant_deny_all_ingress" {
  for_each = local.tenants

  project       = each.value.project_id
  name          = "deny-all-ingress"
  description   = "Explicit, logged default deny"
  network       = module.tenant_vpc[each.key].network_self_link
  direction     = "INGRESS"
  priority      = 65000
  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_firewall" "tenant_deny_all_egress" {
  for_each = local.tenants

  project            = each.value.project_id
  name               = "deny-all-egress"
  description        = "Explicit, logged default deny for outbound traffic"
  network            = module.tenant_vpc[each.key].network_self_link
  direction          = "EGRESS"
  priority           = 65000
  destination_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# =============================================================================
# 4. SECURE DNS
# =============================================================================

locals {
  # Every network that should use the private zones, keyed by owning project.
  dns_networks = merge(
    { shared = { project = var.host_project_id, network = module.shared_vpc.network_self_link } },
    { for k, t in local.tenants : k => { project = t.project_id, network = module.tenant_vpc[k].network_self_link } }
  )
}

# --- Private Google Access via DNS --------------------------------------------
# *.googleapis.com resolves to the private VIP 199.36.153.8/30, which matches
# the private-google-apis route from Phase 3/4. API traffic never needs a
# public IP and never leaves Google's network.

resource "google_dns_managed_zone" "private_googleapis" {
  project     = var.host_project_id
  name        = "private-googleapis"
  dns_name    = "googleapis.com."
  description = "Route all Google API calls to private.googleapis.com"
  visibility  = "private"

  private_visibility_config {
    dynamic "networks" {
      for_each = local.dns_networks
      content {
        network_url = networks.value.network
      }
    }
  }
}

resource "google_dns_record_set" "private_googleapis_a" {
  project      = var.host_project_id
  managed_zone = google_dns_managed_zone.private_googleapis.name
  name         = "private.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"]
}

resource "google_dns_record_set" "private_googleapis_cname" {
  project      = var.host_project_id
  managed_zone = google_dns_managed_zone.private_googleapis.name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["private.googleapis.com."]
}

# --- Internal service names -----------------------------------------------------

resource "google_compute_address" "shared_api" {
  project      = var.host_project_id
  name         = "shared-api-ip"
  description  = "Stable internal IP for the shared services API"
  region       = var.primary_region
  subnetwork   = module.shared_vpc.subnets["shared-svc-subnet"].self_link
  address_type = "INTERNAL"
  address      = "10.0.0.10"
}

resource "google_dns_managed_zone" "internal" {
  project     = var.host_project_id
  name        = "saas-internal"
  dns_name    = "saas.internal."
  description = "Private names for platform services, visible to shared and tenant VPCs only"
  visibility  = "private"

  private_visibility_config {
    dynamic "networks" {
      for_each = local.dns_networks
      content {
        network_url = networks.value.network
      }
    }
  }
}

resource "google_dns_record_set" "shared_api" {
  project      = var.host_project_id
  managed_zone = google_dns_managed_zone.internal.name
  name         = "api.saas.internal."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.shared_api.address]
}

# --- DNS server policy: query logging, no inbound forwarding --------------------

resource "google_dns_policy" "logging" {
  for_each = local.dns_networks

  project                   = each.value.project
  name                      = "dns-logging-policy"
  description               = "Log every DNS query; do not accept queries from outside the VPC"
  enable_logging            = true
  enable_inbound_forwarding = false

  networks {
    network_url = each.value.network
  }
}
