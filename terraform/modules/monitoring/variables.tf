variable "project_id" {
  description = "Scoping project of the metrics scope; alerts here see metrics from every monitored project."
  type        = string
}

variable "alert_email" {
  description = "Email address that receives network alerts."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address."
  }
}

variable "metric_types" {
  description = "Log-based metric types from the logging module (firewall_denied, manual_change)."
  type = object({
    firewall_denied = string
    manual_change   = string
  })
}

variable "enable_hybrid_alerts" {
  description = "Create VPN tunnel and BGP session alerts (only useful while the HA VPN exists)."
  type        = bool
  default     = true
}

variable "firewall_deny_threshold" {
  description = "Denied connections per 5 minutes, across all projects, that count as a spike."
  type        = number
  default     = 20
}
