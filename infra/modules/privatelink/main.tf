###############################################################################
# infra/modules/privatelink/main.tf
#
# One Key Vault, and the private endpoint that is the only way to reach it.
# This is the pattern every later service in the estate copies: the service,
# a private endpoint in the spoke's snet-privatelink, and a DNS zone group
# that writes the endpoint's A record into the matching privatelink zone.
#
# THE VAULT IS NEVER REACHABLE FROM THE INTERNET, NOT EVEN WHILE IT IS BUILT
#
# The build runbook's original draft created this vault with public access
# enabled, wrote a test secret from a laptop, then closed the door in a second
# apply. That sequence was dropped deliberately. Two reasons:
#
#   1. checkov hard-fails the open state on two checks - public network access
#      enabled, and a firewall whose default action is not Deny. The pull
#      request that opened the vault could only merge by carrying two skip
#      comments, and a commit saying this zero-trust vault was briefly open to
#      the internet stays in a public history after the next commit removes
#      them.
#   2. docs/policy-layers.md already records that a later Deny policy on
#      publicNetworkAccess would make that open window impossible anyway.
#      Building it now would mean unbuilding it later.
#
# So the vault is created closed and the test secret is written from inside
# the network, through the private endpoint. The seeding identity at the foot
# of this file exists for exactly that.
#
# WHY THE PRIVATE ENDPOINT IS NOT GATED THE WAY THE FIREWALL IS
#
# A private endpoint bills by the hour, so the obvious move in this estate is
# to treat it like the firewall - absent at rest, present during a session.
# It is not gated, because checkov CKV2_AZURE_32 requires a Key Vault to have
# a private endpoint, and the plan the pipeline scans is the resting state.
# Gating the endpoint would fail that check on every future pull request, or
# force a permanent skip saying this vault has no private endpoint. In a
# public repository named azure-zerotrust-lz that skip is worse than the cost
# it avoids. The endpoint is the cheapest meter here by two orders of
# magnitude; the firewall is the one worth switching off.
#
# WHAT TERRAFORM DOES NOT DO HERE
#
# It never reads or writes a secret. The pipeline runs outside the network and
# holds the control plane only: it can create and configure the vault, and
# cannot see inside it. No azurerm_key_vault_secret belongs in this module,
# because that resource talks to the vault's data plane and would fail from
# the pipeline the moment the vault is closed - which is immediately.
###############################################################################

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.14"
    }
  }
}

# The identity terraform is running as - the CI service principal in the
# pipeline. Read for the tenant the vault trusts and the subscription its name
# is derived from. Never the target of a role assignment: granting the
# pipeline data-plane access is the thing this module exists to avoid.
data "azurerm_client_config" "current" {}

locals {
  # Key Vault names are global across all of Azure and capped at 24
  # characters, so a fixed name would eventually collide with a stranger's
  # vault. The suffix is the first six hex characters of a hash of the
  # subscription ID: unique to this subscription, identical on every rebuild,
  # and derived rather than random, so it does not live only in state.
  #
  # Asking for the same name on a rebuild matters here. Purge protection below
  # keeps a deleted vault's name reserved for its retention period, and
  # providers.tf already sets recover_soft_deleted_key_vaults, so a rebuild
  # inside that window recovers this vault rather than failing on a name that
  # looks taken by nobody.
  key_vault_name = "kv-${var.prefix}-${substr(sha256(data.azurerm_client_config.current.subscription_id), 0, 6)}"
}

resource "azurerm_key_vault" "main" {
  name                = local.key_vault_name
  location            = var.location
  resource_group_name = var.resource_group_name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  # Azure role assignments decide who may read a secret, not the vault's own
  # access-policy list. The difference is the point: under access policies
  # anyone holding Contributor on the vault can add themselves to the list and
  # read everything in it. Under role assignments they cannot - Contributor,
  # and even Owner, carry no right to read a secret at all. The CI identity
  # holds Contributor at subscription scope, so this setting is what stops the
  # pipeline from being able to grant itself the vault's contents.
  rbac_authorization_enabled = true

  # Purge protection cannot be switched off once it is on: this vault cannot
  # be permanently deleted inside its retention window by anyone, the nightly
  # teardown included. Seven days is the shortest retention Azure accepts,
  # chosen because this estate is rebuilt often and a 90-day name reservation
  # would outlive the thing that made it.
  purge_protection_enabled   = true
  soft_delete_retention_days = 7

  # Off from the first apply. The vault has no public data-plane address at
  # all - not an open one, not a firewalled one.
  public_network_access_enabled = false

  network_acls {
    # No trusted-service bypass. That list exists for Azure services which
    # reach a vault from outside the VNet - App Service key references, disk
    # encryption, ARM template deployment. This estate uses none of them, and
    # the list is not something this project can enumerate or audit, so it is
    # not trusted.
    bypass = "None"

    # Deny is belt to public_network_access_enabled's braces: the two settings
    # are independent and checkov checks both. Nothing is added to ip_rules or
    # virtual_network_subnet_ids - the private endpoint is the only path in,
    # and a subnet service endpoint would quietly be a second one.
    default_action = "Deny"
  }

  tags = var.tags
}

###############################################################################
# The private endpoint
###############################################################################

resource "azurerm_private_endpoint" "key_vault" {
  name                = "pe-${var.prefix}-kv"
  location            = var.location
  resource_group_name = var.resource_group_name
  subnet_id           = var.privatelink_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-${var.prefix}-kv"
    private_connection_resource_id = azurerm_key_vault.main.id

    # "vault" is the sub-resource. A private endpoint is per sub-resource
    # rather than per service, which is why a storage account later needs one
    # endpoint per blob/file/queue/table instead of one endpoint.
    subresource_names = ["vault"]

    # Auto-approved: the vault and the endpoint are in one subscription and
    # one terraform run. A manual connection would sit in Pending until
    # somebody approved it in the portal, so the apply would report success
    # while nothing resolved.
    is_manual_connection = false
  }

  # This block is what writes the A record into
  # privatelink.vaultcore.azure.net. Without it the endpoint exists and
  # traffic to its address works, while the vault's name still resolves to the
  # public address - which is switched off. The symptom would be a vault
  # unreachable from inside the network it was built for, with nothing in the
  # apply to say why.
  private_dns_zone_group {
    name                 = "default"
    private_dns_zone_ids = [var.key_vault_private_dns_zone_id]
  }
}

###############################################################################
# The seeding identity
#
# The vault is closed from birth, so the test secret has to be written from
# inside the network. This is the identity that writes it: an ephemeral VM in
# the spoke's workload subnet attaches this identity, asks the instance
# metadata service for a token, and writes the secret over the private
# endpoint.
#
# Why a user-assigned identity rather than the VM's own system-assigned one: a
# system-assigned identity is created and destroyed with its VM, so the role
# assignment would have to be made by the same script that makes the VM, and
# deleting the VM would leave an assignment pointing at a principal that no
# longer exists. This identity and its single role assignment are declared
# here instead - reviewed in a pull request, and readable in the repository.
# Managed identities carry no charge.
#
# Nothing else holds data-plane access on this vault. Not the pipeline, and
# not the human account either, which is what makes the step 5.3 check
# meaningful: see docs/decisions.md.
###############################################################################

resource "azurerm_user_assigned_identity" "seeder" {
  name                = "id-${var.prefix}-kv-seeder"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

resource "azurerm_role_assignment" "seeder_secrets" {
  scope        = azurerm_key_vault.main.id
  principal_id = azurerm_user_assigned_identity.seeder.principal_id

  # Secrets Officer, not Administrator: write and read secrets, with no access
  # to keys or certificates. Not Secrets User either, which is read-only and
  # could not write the secret in the first place.
  role_definition_name = "Key Vault Secrets Officer"

  # Stated rather than left for Azure to infer. Without it the provider looks
  # the principal up in Entra, which fails intermittently for an identity
  # created seconds earlier in the same apply.
  principal_type = "ServicePrincipal"
}

###############################################################################
# Outputs
###############################################################################

output "key_vault_id" {
  description = "Key Vault resource ID."
  value       = azurerm_key_vault.main.id
}

output "key_vault_name" {
  description = "Key Vault name. Scripts read this rather than rebuilding it: the name carries a suffix derived from the subscription ID."
  value       = azurerm_key_vault.main.name
}

output "key_vault_uri" {
  description = "The vault's data-plane address. Reachable only from inside this estate."
  value       = azurerm_key_vault.main.vault_uri
}

output "private_endpoint_ip" {
  description = "Private IP of the vault's private endpoint. This is the address privatelink.vaultcore.azure.net resolves to inside the estate, and checking the two against each other is what proves DNS and the endpoint agree."
  value       = azurerm_private_endpoint.key_vault.private_service_connection[0].private_ip_address
}

output "seeder_identity_id" {
  description = "Resource ID of the seeding identity. The ephemeral VM in runbook step 5.2 attaches this."
  value       = azurerm_user_assigned_identity.seeder.id
}

output "seeder_identity_client_id" {
  description = "Client ID of the seeding identity. A VM carrying more than one identity has to name which one it wants when it asks the instance metadata service for a token."
  value       = azurerm_user_assigned_identity.seeder.client_id
}
