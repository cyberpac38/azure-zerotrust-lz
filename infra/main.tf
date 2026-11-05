###############################################################################
# infra/main.tf
#
# The root calls the modules and nothing else: every resource lives in a
# module, and this file only wires the root's variables into them.
#
#   network - VNets, subnets, peering, route tables, NSGs, firewall policy,
#             and the firewall itself when var.firewall_enabled is true
#   dns     - private DNS zones for private endpoints, and the VNet links
#             that make each zone authoritative inside this estate
###############################################################################

module "network" {
  source = "./modules/network"

  prefix           = var.prefix
  location         = var.location
  tags             = var.tags
  firewall_enabled = var.firewall_enabled
}

module "dns" {
  source = "./modules/dns"

  prefix   = var.prefix
  location = var.location
  tags     = var.tags

  # Module references, not literal names. This is the dependency edge that
  # makes Terraform create the hub resource group and all three VNets before
  # any zone or link. A literal "rg-ztlz-hub" here would plan fine and race
  # the resource group on a fresh build.
  hub_resource_group_name = module.network.hub_resource_group_name

  # Every VNet that has to resolve privatelink names, keyed to match the
  # link_to lists in the module's private_dns_zones default. The hub is
  # included deliberately: if the firewall's DNS proxy is ever pointed at
  # (runbook step 4.4, currently unresolved), the zones must already be
  # linked to the hub, and adding that later churns the same 24 links.
  vnet_ids = merge(
    { hub = module.network.hub_vnet_id },
    module.network.spoke_vnet_ids
  )
}
