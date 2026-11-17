variable "prefix" {
  type        = string
  description = "Resource name prefix, e.g. ztlz."
}

variable "enforce_policy" {
  type        = bool
  description = "Assignment enforcement mode. false suspends enforcement while keeping the compliance signal; true blocks non-compliant create and update."
  default     = false
}

variable "state_resource_group_name" {
  type        = string
  description = "Resource group holding the Terraform state account, exempted from the public-network-access Deny."
}

variable "excluded_resource_group_names" {
  type        = list(string)
  description = "Resource groups that merely share this subscription and must not be governed by the baseline (e.g. unrelated projects). Carved out of the assignment via not_scopes."
  default     = []
}
