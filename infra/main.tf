###############################################################################
# infra/main.tf
#
# The root calls one module. Everything the landing zone's network is made of
# lives in modules/network; this file only wires the root's variables into it.
###############################################################################

module "network" {
  source = "./modules/network"

  prefix           = var.prefix
  location         = var.location
  tags             = var.tags
  firewall_enabled = var.firewall_enabled
}
