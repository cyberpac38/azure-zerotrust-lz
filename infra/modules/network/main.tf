###############################################################################
# infra/modules/network/main.tf
#
# Hub-and-spoke. The hub holds the firewall; spokes hold workloads and private
# endpoints; all spoke egress is forced through the hub.
#
# WHAT IS GATED BY var.firewall_enabled, AND WHAT IS NOT
#
#   Gated   : azurerm_firewall, azurerm_public_ip
#             These are the only two resources that bill by the hour.
#
#   Ungated : azurerm_firewall_policy
#             A policy with zero or one firewall association is free, so there
#             is no cost reason to remove it - and it is where every rule from
#             Phase 4 onward lives. Gating it would delete the estate's rules
#             every time the firewall came down.
#
#   Ungated : azurerm_route_table, azurerm_subnet_route_table_association
#             This is the important one. If the route tables disappeared with
#             the firewall, then with firewall_enabled = false - the steady
#             state, the state every unattended apply converges to - Azure's
#             default system route would take over and every spoke would have
#             direct unfiltered internet egress. The resting state of a
#             zero-trust landing zone would be open egress.
#
#             Instead the route is always present and only its next hop
#             changes: "None" (Azure drops the traffic) when the firewall is
#             absent, "VirtualAppliance" when it is present. Resting state is
#             "spokes cannot reach the internet"; bringing the firewall up
#             relaxes that to "spokes reach the internet through an inspected
#             path". Failure mode of a forgotten flag is lost egress, not
#             silent unfiltered egress.
###############################################################################

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }
}

###############################################################################
# Hub
###############################################################################

resource "azurerm_resource_group" "hub" {
  name     = "rg-${var.prefix}-hub"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.prefix}-hub"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  address_space       = [var.hub_address_space]
  tags                = var.tags
}

# The name is mandated by Azure: the subnet must be called exactly
# "AzureFirewallSubnet" and be /26 or larger. variables.tf enforces a hub of
# /22 or larger so this derivation cannot produce anything smaller.
#
# No route table is associated with this subnet, deliberately. A 0.0.0.0/0 UDR
# on AzureFirewallSubnet pointing at the firewall's own private IP is a
# routing loop.
resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.hub_address_space, 4, 0)]
}

###############################################################################
# Firewall policy - ungated, free at zero or one association
###############################################################################

# DNS proxy is the reason this is Standard rather than Basic: it is what lets
# the firewall answer privatelink queries on behalf of the spokes, which
# Phase 3 depends on. Enabling it here, before any zone exists, means Phase 3
# adds zones to a firewall that is already the resolver rather than changing
# the resolver and the zones in the same step.
resource "azurerm_firewall_policy" "main" {
  # checkov:skip=CKV_AZURE_220:IDPS requires the Premium SKU. This project runs Standard deliberately - Premium roughly triples the hourly rate and demonstrates nothing this landing zone claims. Revisit only if the tier changes.
  name                = "afwp-${var.prefix}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = "Standard"

  dns {
    proxy_enabled = true
  }

  tags = var.tags
}

###############################################################################
# Firewall and its public IP - the only hourly-billed resources here
###############################################################################

resource "azurerm_public_ip" "firewall" {
  count = var.firewall_enabled ? 1 : 0

  name                = "pip-${var.prefix}-fw"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_firewall" "main" {
  count = var.firewall_enabled ? 1 : 0

  name                = "afw-${var.prefix}"
  location            = azurerm_resource_group.hub.location
  resource_group_name = azurerm_resource_group.hub.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.main.id

  ip_configuration {
    name                 = "primary"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall[0].id
  }

  tags = var.tags
}

###############################################################################
# Spokes
###############################################################################

resource "azurerm_resource_group" "spoke" {
  for_each = var.spokes

  name     = "rg-${var.prefix}-${each.key}"
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "spoke" {
  for_each = var.spokes

  name                = "vnet-${var.prefix}-${each.key}"
  location            = azurerm_resource_group.spoke[each.key].location
  resource_group_name = azurerm_resource_group.spoke[each.key].name
  address_space       = [each.value.address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "workload" {
  for_each = var.spokes

  name                 = "snet-workload"
  resource_group_name  = azurerm_resource_group.spoke[each.key].name
  virtual_network_name = azurerm_virtual_network.spoke[each.key].name
  address_prefixes     = [cidrsubnet(each.value.address_space, 4, 0)]
}

# Private endpoint NICs land here from Phase 4 onward. This subnet gets NO
# route table: a 0.0.0.0/0 UDR on a private endpoint subnet interferes with
# private endpoint traffic, and private endpoints do not egress to the
# internet in the first place, so there is nothing to force through the
# firewall. private_endpoint_network_policies is deliberately left at the
# provider default and is Phase 4's concern, not this module's.
resource "azurerm_subnet" "privatelink" {
  for_each = var.spokes

  name                 = "snet-privatelink"
  resource_group_name  = azurerm_resource_group.spoke[each.key].name
  virtual_network_name = azurerm_virtual_network.spoke[each.key].name
  address_prefixes     = [cidrsubnet(each.value.address_space, 4, 1)]
}

###############################################################################
# Peering
#
# Spoke-to-spoke traffic goes spoke A -> firewall in the hub -> spoke B. On the
# second leg the packet's source is spoke A, not the hub, which makes it
# FORWARDED traffic from spoke B's point of view - so hub-to-spoke must set
# allow_forwarded_traffic = true or the firewall's forwarded packets are
# dropped at the peering. The spoke-to-hub direction carries only traffic
# originating in that spoke, so it does not need the same grant, and leaving
# it false means a compromised spoke cannot use the peering to forward on
# behalf of anything else.
###############################################################################

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each = var.spokes

  name                         = "peer-hub-to-${each.key}"
  resource_group_name          = azurerm_resource_group.hub.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.spoke[each.key].id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  for_each = var.spokes

  name                         = "peer-${each.key}-to-hub"
  resource_group_name          = azurerm_resource_group.spoke[each.key].name
  virtual_network_name         = azurerm_virtual_network.spoke[each.key].name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  use_remote_gateways          = false
}

###############################################################################
# Egress routing - always present, next hop conditional
###############################################################################

resource "azurerm_route_table" "spoke" {
  for_each = var.spokes

  name                = "rt-${var.prefix}-${each.key}"
  location            = azurerm_resource_group.spoke[each.key].location
  resource_group_name = azurerm_resource_group.spoke[each.key].name
  tags                = var.tags

  # "None" makes Azure DROP traffic to the prefix rather than fall back to the
  # default system route. That is what keeps "no egress" as the resting state
  # when the firewall is absent.
  #
  # next_hop_in_ip_address is only meaningful for VirtualAppliance and is null
  # otherwise. The conditional does not fault on the [0] index when
  # firewall_enabled is false - verified by applying the gated pattern in all
  # three states, including the enabled -> disabled transition that up.sh and
  # down.sh perform.
  route {
    name                   = "default-egress"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = var.firewall_enabled ? "VirtualAppliance" : "None"
    next_hop_in_ip_address = var.firewall_enabled ? azurerm_firewall.main[0].ip_configuration[0].private_ip_address : null
  }
}

resource "azurerm_subnet_route_table_association" "workload" {
  for_each = var.spokes

  subnet_id      = azurerm_subnet.workload[each.key].id
  route_table_id = azurerm_route_table.spoke[each.key].id
}

###############################################################################
# Outputs
###############################################################################

output "hub_vnet_id" {
  description = "Hub VNet resource ID. Phase 3 links private DNS zones to it."
  value       = azurerm_virtual_network.hub.id
}

output "spoke_vnet_ids" {
  description = "Spoke VNet resource IDs by spoke key. Phase 3 links private DNS zones to each."
  value       = { for k, v in azurerm_virtual_network.spoke : k => v.id }
}

output "spoke_workload_subnet_ids" {
  description = "Workload subnet IDs by spoke key. This is the subnet the 3.8 route verification VM goes into."
  value       = { for k, v in azurerm_subnet.workload : k => v.id }
}

output "spoke_privatelink_subnet_ids" {
  description = "Private endpoint subnet IDs by spoke key. Phase 4 places private endpoints here."
  value       = { for k, v in azurerm_subnet.privatelink : k => v.id }
}

output "firewall_policy_id" {
  description = "Firewall policy ID. Exists whether or not a firewall does; Phase 4 attaches rule collection groups to it."
  value       = azurerm_firewall_policy.main.id
}

# null when firewall_enabled is false. Step 3.9 reads this, and Phase 3 uses it
# as the DNS forwarder address. It changes on every recreate, so nothing should
# hardcode a value read from it.
output "firewall_private_ip" {
  description = "Private IP of the firewall, or null when firewall_enabled is false."
  value       = var.firewall_enabled ? azurerm_firewall.main[0].ip_configuration[0].private_ip_address : null
}

###############################################################################
# Network security groups
#
# WHY THESE EXIST: four subnets with no NSG is the gap checkov CKV2_AZURE_31
# reports, and on a zero-trust landing zone it is a real finding rather than a
# scanner being pedantic. The route table controls where egress GOES; an NSG
# controls what may arrive. Both are needed and neither substitutes.
#
# AzureFirewallSubnet deliberately has none: Azure does not support an NSG on
# that subnet, and checkov knows this and does not ask for one.
#
# WHAT IS NOT DONE HERE, AND WHY IT MATTERS
#
# No explicit deny-all-inbound rule is added. Azure's own default rules
# already end with DenyAllInBound at priority 65500, and they begin with
# AllowVnetInBound at 65000. A custom "deny everything from *" rule at any
# priority below 65000 would also match VNet-sourced traffic - which is the
# firewall's forwarded spoke-to-spoke traffic, and the hub reaching the
# spokes. That one rule would silently break the hub-and-spoke design while
# looking like good hygiene.
#
# What is added instead is an EXPLICIT deny of Internet-sourced inbound. It is
# redundant with Azure's default, deliberately: a default is an assumption a
# reader has to know about, whereas an explicit rule is visible in the portal,
# in `az network nsg rule list`, and in any audit export. Same reasoning as
# next_hop_type = "None" - state the intent rather than relying on a fallback.
###############################################################################

resource "azurerm_network_security_group" "workload" {
  for_each = var.spokes

  name                = "nsg-${var.prefix}-${each.key}-workload"
  location            = azurerm_resource_group.spoke[each.key].location
  resource_group_name = azurerm_resource_group.spoke[each.key].name
  tags                = var.tags

  # Explicit, auditable restatement of Azure's default DenyAllInBound, scoped
  # to Internet so VNet traffic (the firewall's forwarded packets) is
  # untouched. Priority 4000 leaves 1-3999 free for the application-specific
  # allows that Phase 5 onward will need.
  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "privatelink" {
  for_each = var.spokes

  name                = "nsg-${var.prefix}-${each.key}-privatelink"
  location            = azurerm_resource_group.spoke[each.key].location
  resource_group_name = azurerm_resource_group.spoke[each.key].name
  tags                = var.tags

  # A private endpoint subnet should never receive anything from the internet
  # and never originate anything to it. The outbound rule is the half most
  # private-endpoint subnets forget: a compromised endpoint NIC calling out is
  # exactly the exfiltration path private endpoints are meant to remove.
  #
  # NOTE for Phase 4: NSG rules only apply to private endpoint traffic when
  # the subnet has private_endpoint_network_policies enabled. This module
  # leaves that at the provider default, so Phase 4 must set it when it places
  # endpoints here - otherwise these rules exist and enforce nothing.
  security_rule {
    name                       = "deny-internet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-internet-outbound"
    priority                   = 4000
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "workload" {
  for_each = var.spokes

  subnet_id                 = azurerm_subnet.workload[each.key].id
  network_security_group_id = azurerm_network_security_group.workload[each.key].id
}

resource "azurerm_subnet_network_security_group_association" "privatelink" {
  for_each = var.spokes

  subnet_id                 = azurerm_subnet.privatelink[each.key].id
  network_security_group_id = azurerm_network_security_group.privatelink[each.key].id
}

output "workload_nsg_ids" {
  description = "Workload NSG IDs by spoke key. Phase 5 adds application-specific allow rules to these."
  value       = { for k, v in azurerm_network_security_group.workload : k => v.id }
}
