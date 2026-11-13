###############################################################################
# infra/modules/privatelink/variables.tf
#
# Inputs for the Key Vault and its private endpoint.
#
# There is no switch for public access and none for whether the endpoint
# exists. Both were considered and both were dropped - main.tf records why at
# length. The short version: the vault is closed from its first apply and the
# endpoint is permanent, so neither state is configurable and neither can be
# left in the wrong position by a forgotten flag.
###############################################################################

variable "prefix" {
  description = "Short name prefix, passed down from the root."
  type        = string
}

variable "location" {
  description = "Azure region for the vault, its private endpoint and the seeding identity. Note that the private DNS zone the endpoint writes into is global and takes no region."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
}

variable "resource_group_name" {
  description = "Resource group for the vault, its private endpoint and the seeding identity. Passed as a module reference from the network module rather than as a literal name, so terraform orders the resource group before these resources on a fresh build."
  type        = string
}

variable "privatelink_subnet_id" {
  description = "The snet-privatelink subnet the private endpoint's network interface is placed in. That subnet carries no route table deliberately, and has private endpoint network policies switched on so its NSG rules apply to this endpoint's traffic."
  type        = string
}

variable "key_vault_private_dns_zone_id" {
  description = "Resource ID of the privatelink.vaultcore.azure.net zone. The endpoint's DNS zone group writes its A record here, which is what makes the vault's own name resolve to a private address inside the estate."
  type        = string
}
