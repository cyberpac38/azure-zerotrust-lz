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
  description = "Tags applied to every resource. Enforced by policy in Phase 9."
  type        = map(string)
  default = {
    owner   = "cyberpac38"
    env     = "lab"
    project = "ztlz"
  }
}
