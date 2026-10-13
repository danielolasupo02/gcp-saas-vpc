variable "project_id" {
  description = "Project that owns the network."
  type        = string
}

variable "name" {
  description = "Short name for this egress gateway (used in router, NAT and IP names)."
  type        = string
}

variable "region" {
  description = "Region of the NAT gateway. Cloud NAT is regional."
  type        = string
}

variable "network" {
  description = "Self link of the VPC network."
  type        = string
}

variable "subnetworks" {
  description = "Subnet self links to NAT. Empty list = every subnet in the region."
  type        = list(string)
  default     = []
}

variable "nat_ip_count" {
  description = "Number of reserved static external IPs. Two or more gives IP-level failover."
  type        = number
  default     = 1

  validation {
    condition     = var.nat_ip_count >= 1 && var.nat_ip_count <= 10
    error_message = "nat_ip_count must be between 1 and 10."
  }
}

variable "log_filter" {
  description = "NAT logging: ERRORS_ONLY, TRANSLATIONS_ONLY or ALL."
  type        = string
  default     = "ERRORS_ONLY"

  validation {
    condition     = contains(["ERRORS_ONLY", "TRANSLATIONS_ONLY", "ALL"], var.log_filter)
    error_message = "log_filter must be ERRORS_ONLY, TRANSLATIONS_ONLY or ALL."
  }
}

variable "min_ports_per_vm" {
  description = "Minimum NAT source ports reserved per VM."
  type        = number
  default     = 64
}

variable "max_ports_per_vm" {
  description = "Maximum NAT source ports a busy VM can grow to (dynamic port allocation)."
  type        = number
  default     = 4096
}
