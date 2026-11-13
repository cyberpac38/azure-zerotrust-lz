###############################################################################
# infra/modules/dns/main.tf
#
# One azurerm_private_dns_zone per zone name, and one
# azurerm_private_dns_zone_virtual_network_link per zone-and-VNet pair.
#
# Why the links are flattened into individual resources rather than generated
# inside the zone resource: linking a zone is the dangerous operation in this
# phase. The link is what makes the zone authoritative for its namespace
# inside a VNet, and therefore what can return authoritative NXDOMAIN for
# every name under it. An operation with that consequence must appear on its
# own line in a plan, never folded invisibly into a zone's diff.
#
# Why these zones are created now, while the estate is empty: measured on
# 2026-11-04, this subscription held zero private DNS zones, zero private
# endpoints, zero VMs and zero clusters, and all three VNets had an empty
# dnsServers list - Azure-provided DNS. Nothing is querying these names, so an
# empty linked zone has provably no blast radius today. The private endpoints
# phase then writes its own A records through each endpoint's DNS zone
# group. Building the zones at any later point means linking them while
# something is already resolving through them.
#
# Private DNS zones are global resources: neither resource here takes a
# location argument, and this module takes no region at all.
###############################################################################

locals {
  zones = var.private_dns_zones

  # The product of zones and their link targets. Keyed by zone and VNet key so
  # that adding a spoke adds links without renaming or recreating an existing
  # one - a renamed link is a destroy and create, which momentarily removes
  # the zone's authority over that VNet.
  zone_links = merge([
    for zone_name, cfg in local.zones : {
      for vnet_key in cfg.link_to :
      "${zone_name}|${vnet_key}" => {
        zone_name = zone_name
        vnet_key  = vnet_key
      }
    }
  ]...)
}

resource "azurerm_private_dns_zone" "this" {
  for_each = local.zones

  name                = each.key
  resource_group_name = var.hub_resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  for_each = local.zone_links

  name                  = replace("${each.value.vnet_key}-${each.value.zone_name}", ".", "-")
  resource_group_name   = var.hub_resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this[each.value.zone_name].name
  virtual_network_id    = var.vnet_ids[each.value.vnet_key]

  # No auto-registration. These zones hold private endpoint A records, written
  # by each endpoint's DNS zone group - not VM hostnames. Registration on a
  # privatelink zone would let a VM name collide with a service record.
  registration_enabled = false

  resolution_policy = var.resolution_policy

  tags = var.tags
}

output "zone_ids" {
  description = "Private DNS zone resource IDs by zone name. The private endpoints phase passes the Key Vault zone ID into its private endpoint's DNS zone group; without that group the endpoint exists, routing works, and nothing resolves to it."
  value       = { for k, v in azurerm_private_dns_zone.this : k => v.id }
}

output "zone_names" {
  description = "Zone names actually created."
  value       = sort(keys(azurerm_private_dns_zone.this))
}

output "link_count" {
  description = "Number of virtual network links created. Check this against the plan: it is zones multiplied by their link targets, and a number lower than expected means a link_to list is shorter than intended."
  value       = length(azurerm_private_dns_zone_virtual_network_link.this)
}
