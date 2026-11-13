###############################################################################
# infra/modules/network/variables.tf
#
# The hub-and-spoke module's inputs. Every validation here exists to turn a
# misconfiguration into a PLAN-TIME error rather than an apply-time Azure
# error, because an Azure error arrives after resources have already started
# being created and leaves a half-built estate behind.
###############################################################################

variable "prefix" {
  description = "Short name prefix for every resource in this landing zone."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.prefix))
    error_message = "prefix must be 2-10 lowercase alphanumeric characters."
  }
}

variable "location" {
  description = "Azure region for the hub and all spokes. One region for the whole estate."
  type        = string
}

# NO DEFAULT, deliberately. The runbook's version defaults to
# owner=unassigned,env=lab. A default means that forgetting to pass tags from
# the root produces a silently mis-tagged estate that still applies cleanly -
# and the policy repository phase enforces owner/env by policy, so the
# failure would surface later
# as a compliance finding against resources this module created. With no
# default, forgetting is a plan-time error naming the missing argument.
variable "tags" {
  description = "Tags applied to every taggable resource. Passed from the root; owner and env are enforced by policy in the policy repository phase."
  type        = map(string)
}

# The firewall's EXISTENCE, not its configuration.
#
# Default false because false is the steady state. deploy.yml applies on every
# merge touching infra/**, unattended apart from the prod approval gate, and
# nightly-teardown.yml deletes any firewall in rg-ztlz-* at 04:23 UTC. If the
# declared state were "present", every merge would recreate what the teardown
# removed and the meter would restart without anyone deciding it should.
#
# What this flag does NOT gate: the route tables, their subnet associations,
# and the firewall policy. See the route table's next_hop in main.tf - the
# route is always present, and only its next hop changes. Gating the route
# tables would make unrestricted internet egress the resting state of a
# zero-trust landing zone.
variable "firewall_enabled" {
  description = "Whether the Azure Firewall and its public IP exist. False is the steady state; up.sh/down.sh flip it for a work session."
  type        = bool
  default     = false
}

variable "hub_address_space" {
  description = "CIDR for the hub VNet. Must be /22 or larger so the derived AzureFirewallSubnet is /26 or larger."
  type        = string
  default     = "10.10.0.0/22"

  validation {
    condition     = can(cidrhost(var.hub_address_space, 0))
    error_message = "hub_address_space must be a valid CIDR block, e.g. 10.10.0.0/22."
  }

  # main.tf derives AzureFirewallSubnet as cidrsubnet(hub, 4, 0), which adds 4
  # bits. Azure rejects an AzureFirewallSubnet smaller than /26. 22 + 4 = 26,
  # so a hub prefix longer than /22 produces a subnet Azure refuses - and it
  # refuses it at apply, after the resource group and VNet already exist.
  validation {
    condition     = can(cidrhost(var.hub_address_space, 0)) && tonumber(split("/", var.hub_address_space)[1]) <= 22
    error_message = "hub_address_space must be /22 or larger (a smaller prefix number). AzureFirewallSubnet is derived as a /26 from it and Azure rejects anything smaller."
  }
}

variable "spokes" {
  description = "Spoke VNets keyed by short name. Adding a spoke is a tfvars change, not a code change."
  type = map(object({
    address_space = string
  }))
  default = {
    workload = { address_space = "10.20.0.0/20" }
    shared   = { address_space = "10.21.0.0/20" }
  }

  validation {
    condition     = length(var.spokes) > 0
    error_message = "at least one spoke is required; the hub exists to route for spokes."
  }

  # Keys become resource names: rg-<prefix>-<key>, vnet-<prefix>-<key>,
  # rt-<prefix>-<key>. An uppercase or punctuated key produces a name Azure
  # rejects at apply.
  validation {
    condition     = alltrue([for k, v in var.spokes : can(regex("^[a-z0-9]{1,12}$", k))])
    error_message = "each spoke key must be 1-12 lowercase alphanumeric characters; keys are used verbatim in resource names."
  }

  validation {
    condition     = alltrue([for k, v in var.spokes : can(cidrhost(v.address_space, 0))])
    error_message = "every spoke address_space must be a valid CIDR block, e.g. 10.20.0.0/20."
  }

  # main.tf derives snet-workload as cidrsubnet(spoke, 4, 0) and
  # snet-privatelink as cidrsubnet(spoke, 4, 1), both adding 4 bits. A /24
  # spoke yields /28 subnets, which is the floor worth allowing: Azure
  # reserves five addresses in every subnet, and the privatelink subnet has to
  # hold one NIC per private endpoint from the private endpoints phase
  # onward.
  validation {
    condition = alltrue([
      for k, v in var.spokes :
      can(cidrhost(v.address_space, 0)) && tonumber(split("/", v.address_space)[1]) <= 24
    ])
    error_message = "every spoke address_space must be /24 or larger; the workload and privatelink subnets are derived from it as /28s or larger."
  }

  # OVERLAP GUARD, spoke against hub.
  #
  # Overlapping address space does not fail at VNet creation. It fails at
  # PEERING creation, after both VNets exist, with an error that names the
  # peering rather than the overlap - so the diagnosis costs an evening and
  # the fix costs a destroy. Caught here instead.
  #
  # The test: take one block's first address, re-mask it with the other
  # block's prefix length, and compare to that block's network address. If
  # they match, the first block starts inside the second. Run in both
  # directions, because either block may be the larger one.
  validation {
    condition = alltrue([
      for k, v in var.spokes :
      !(
        cidrhost(format("%s/%s", cidrhost(v.address_space, 0), split("/", var.hub_address_space)[1]), 0) == cidrhost(var.hub_address_space, 0)
        ||
        cidrhost(format("%s/%s", cidrhost(var.hub_address_space, 0), split("/", v.address_space)[1]), 0) == cidrhost(v.address_space, 0)
      )
    ])
    error_message = "a spoke address_space overlaps hub_address_space. Overlapping spaces apply cleanly and then fail at peering creation."
  }

  # OVERLAP GUARD, spoke against spoke. setproduct gives ordered pairs, so a
  # single directional test per pair covers both directions across the set.
  validation {
    condition = alltrue([
      for pair in setproduct(keys(var.spokes), keys(var.spokes)) :
      pair[0] == pair[1] ? true : !(
        cidrhost(format("%s/%s", cidrhost(var.spokes[pair[1]].address_space, 0), split("/", var.spokes[pair[0]].address_space)[1]), 0)
        == cidrhost(var.spokes[pair[0]].address_space, 0)
      )
    ])
    error_message = "two spoke address_space values overlap. Spoke-to-spoke traffic routes through the hub firewall, so every spoke must be distinct."
  }
}
