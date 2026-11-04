variable "prefix" {
  description = "Short name prefix for every resource in this landing zone."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.prefix))
    error_message = "prefix must be 2-10 lowercase alphanumeric characters."
  }
}

variable "location" {
  description = "Azure region. One region for the whole estate."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource. Enforced by policy in Phase 7."
  type        = map(string)
  default = {
    owner   = "cyberpac38"
    env     = "lab"
    project = "ztlz"
  }
}

variable "firewall_enabled" {
  description = "Whether the Azure Firewall and its hourly-billed public IP exist. False is the steady state: deploy.yml applies unattended and the nightly workflow tears the firewall down, so 'absent' must be what the configuration declares. up.sh and down.sh flip this for a work session."
  type        = bool
  default     = false
}
