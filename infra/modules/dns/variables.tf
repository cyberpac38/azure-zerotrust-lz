###############################################################################
# infra/modules/dns/variables.tf
#
# Private DNS zones for private endpoints, and the virtual network links that
# make each zone authoritative inside this estate.
###############################################################################

variable "prefix" {
  description = "Short name prefix. Used in tags only - zone names are fixed by Azure and cannot carry a prefix."
  type        = string
}

variable "location" {
  description = "Azure region. Needed because the Container Registry data-endpoint zone name embeds the region: <region>.data.privatelink.azurecr.io."
  type        = string
}

variable "tags" {
  description = "Tags applied to every zone and every link."
  type        = map(string)
}

variable "hub_resource_group_name" {
  description = "Resource group that holds every zone. Passed as a module reference rather than a literal name so Terraform orders the resource group before the zones on a fresh build."
  type        = string
}

variable "vnet_ids" {
  description = "VNet resource IDs by short key - the hub and every spoke. A zone is authoritative only for a VNet it is linked to, so every VNet that must resolve privatelink names has to appear here. Keys must match the link_to values in var.private_dns_zones."
  type        = map(string)
}

variable "private_dns_zones" {
  description = <<-EOT
    Zone names to create, and which keys of var.vnet_ids each is linked to.

    Every name here is taken from Microsoft's "Azure Private Endpoint private
    DNS zone values" page. A name typed from memory, or inferred from the
    pattern of another service, is the worst failure available in this module:
    a wrong-but-linked zone captures its entire namespace and returns
    authoritative NXDOMAIN for everything under it, where a missing zone would
    have fallen through to public DNS and kept working.

    Deliberately narrowed to the services this estate will actually hold
    private endpoints for. SQL, Cosmos DB, App Service and Service Bus are
    absent on purpose: a zone for a service that never gets an endpoint is
    exactly the failure above, manufactured for no benefit. Adding a service
    later is one entry here, reviewed like any other change.

    The Container Registry data-endpoint zone is added in main.tf instead,
    because its name is computed from var.location and cannot appear in a
    variable default.
  EOT
  type = map(object({
    link_to = list(string)
  }))
  default = {
    # Phase 4 - Key Vault
    "privatelink.vaultcore.azure.net" = { link_to = ["hub", "workload", "shared"] }

    # Phase 5 - Container Registry, control plane. The region-scoped data
    # endpoint zone is added in main.tf.
    "privatelink.azurecr.io" = { link_to = ["hub", "workload", "shared"] }

    # Phases 11-12 - Azure Monitor private link scope. All four names belong to
    # one service; a partial set resolves some Monitor calls and not others,
    # which is harder to diagnose than none of them resolving.
    "privatelink.monitor.azure.com"             = { link_to = ["hub", "workload", "shared"] }
    "privatelink.oms.opinsights.azure.com"      = { link_to = ["hub", "workload", "shared"] }
    "privatelink.ods.opinsights.azure.com"      = { link_to = ["hub", "workload", "shared"] }
    "privatelink.agentsvc.azure-automation.net" = { link_to = ["hub", "workload", "shared"] }

    # Phase 11 flow log storage, and required by the Azure Monitor set above.
    # One zone resource, two consumers - which is why links are flattened.
    "privatelink.blob.core.windows.net" = { link_to = ["hub", "workload", "shared"] }
  }
}

variable "acr_data_zone_link_to" {
  description = "VNet keys the region-scoped Container Registry data zone is linked to. Separate from private_dns_zones because its name is computed from var.location rather than written literally."
  type        = list(string)
  default     = ["hub", "workload", "shared"]
}

variable "resolution_policy" {
  description = <<-EOT
    resolutionPolicy on every virtual network link: "Default" or
    "NxDomainRedirect".

    Default on purpose. NxDomainRedirect - the portal's "Enable fallback to
    internet" - makes Azure's recursive resolver retry against the public
    endpoint name whenever a linked zone answers NXDOMAIN. That is the right
    choice for a general estate and the wrong one here: it converts a missing
    or misnamed record from a loud DNS failure into a silent connection to the
    public endpoint, which once Phase 4 disables public network access
    surfaces as a 403 from an unexpected direction rather than as the DNS
    fault it actually is. It would also make Phase 13's deliberate
    break-a-DNS-record drill prove nothing.

    Confirmed present in azurerm 4.81.0 by reading the provider source at tag
    v4.81.0: Optional + Computed, validated against the SDK value list, and
    not ForceNew - so changing this later is an in-place link update, not a
    rebuild. The provider notes the service sets its own default for
    private-link zones, which is the reason to state it explicitly here.
  EOT
  type        = string
  default     = "Default"
  validation {
    condition     = contains(["Default", "NxDomainRedirect"], var.resolution_policy)
    error_message = "resolution_policy must be exactly \"Default\" or \"NxDomainRedirect\"."
  }
}
