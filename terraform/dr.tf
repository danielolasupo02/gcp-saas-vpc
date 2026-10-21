###############################################################################
# Phase 8 — Disaster recovery
#
#   Pilot-light DR region (us-east1), already provisioned and costing nothing at rest:
#     shared-vpc-network : prod-subnet-east (Phase 3), shared-svc-subnet-east
#     tenant VPCs        : fintech-subnet-east, health-subnet-east
#     egress             : nat-shared-east-prod (Phase 6); tenant DR NAT behind
#                          var.enable_dr_egress
#   Firewall rules use /16 blocks and service accounts, and every shared-svc rule
#   covers both shared-svc ranges, so failover needs no security changes.
#
#   Config backups: scripts/backup_config.sh exports every network object to a
#   versioned bucket that lives in the DR region, not next to what it protects.
#   Terraform state is protected separately by the versioned state bucket.
###############################################################################

resource "google_storage_bucket" "config_backups" {
  project                     = var.host_project_id
  name                        = "${var.host_project_id}-network-config-backups"
  location                    = var.secondary_region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true # lab only; production would keep a locked retention policy

  versioning {
    enabled = true
  }

  # Keep backups 180 days; keep at most 5 older versions of any overwritten object.
  lifecycle_rule {
    condition {
      age = 180
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 5
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    owner   = "platform"
    purpose = "network-config-backup"
  }
}
