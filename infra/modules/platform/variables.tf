variable "prefix" {
  type        = string
  description = "Resource name prefix, e.g. ztlz."
}

variable "location" {
  type        = string
  description = "Azure region for the platform resource group and workspace."
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource in this module."
}
