variable "project_id" {
  description = "Project that owns the network."
  type        = string
}

variable "network_name" {
  description = "VPC network name."
  type        = string
}

variable "description" {
  description = "Network description."
  type        = string
  default     = ""
}

variable "routing_mode" {
  description = "REGIONAL or GLOBAL dynamic routing."
  type        = string
  default     = "GLOBAL"

  validation {
    condition     = contains(["REGIONAL", "GLOBAL"], var.routing_mode)
    error_message = "routing_mode must be REGIONAL or GLOBAL."
  }
}

variable "mtu" {
  description = "Network MTU. Keep identical across peered VPCs."
  type        = number
  default     = 1460
}

variable "delete_default_routes" {
  description = "Remove the auto-created 0.0.0.0/0 route so every route is explicit and owned by Terraform."
  type        = bool
  default     = true
}

variable "subnets" {
  description = "Subnets keyed by name."
  type = map(object({
    cidr        = string
    region      = string
    description = optional(string, "")
  }))
}

variable "flow_logs" {
  description = "VPC Flow Logs settings applied to every subnet."
  type = object({
    enabled              = optional(bool, true)
    aggregation_interval = optional(string, "INTERVAL_5_SEC")
    flow_sampling        = optional(number, 0.5)
    metadata             = optional(string, "INCLUDE_ALL_METADATA")
  })
  default = {}
}

variable "routes" {
  description = "Custom static routes keyed by name. Next hop defaults to the default internet gateway."
  type = map(object({
    dest_range       = string
    next_hop_gateway = optional(string, "default-internet-gateway")
    priority         = optional(number, 1000)
    tags             = optional(list(string), [])
    description      = optional(string, "")
  }))
  default = {}
}
