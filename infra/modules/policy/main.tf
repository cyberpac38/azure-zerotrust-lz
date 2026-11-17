data "azurerm_subscription" "current" {}

data "azurerm_resource_group" "state" {
  name = var.state_resource_group_name
}

locals {
  policy_files = fileset("${path.module}/../../../policy/definitions", "*.json")

  policy_definitions = {
    for f in local.policy_files :
    trimsuffix(f, ".json") => jsondecode(file("${path.module}/../../../policy/definitions/${f}"))
  }
}

resource "azurerm_policy_definition" "this" {
  for_each = local.policy_definitions

  name         = each.key
  policy_type  = "Custom"
  mode         = lookup(each.value.properties, "mode", "All")
  display_name = each.value.properties.displayName
  description  = each.value.properties.description

  metadata    = jsonencode(each.value.properties.metadata)
  parameters  = jsonencode(each.value.properties.parameters)
  policy_rule = jsonencode(each.value.properties.policyRule)
}

resource "azurerm_policy_set_definition" "baseline" {
  name         = "${var.prefix}-baseline"
  policy_type  = "Custom"
  display_name = "${var.prefix} zero-trust baseline"

  dynamic "policy_definition_reference" {
    for_each = azurerm_policy_definition.this
    content {
      policy_definition_id = policy_definition_reference.value.id
      reference_id         = policy_definition_reference.key
    }
  }
}

resource "azurerm_subscription_policy_assignment" "baseline" {
  name                 = "${var.prefix}-baseline"
  display_name         = "${var.prefix} zero-trust baseline"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = azurerm_policy_set_definition.baseline.id

  # Resource groups that merely share this subscription (unrelated projects)
  # are carved out, so the baseline governs only the landing zone and the
  # compliance signal stays about it. Scope strings are built from the names
  # the root supplies.
  not_scopes = [
    for name in var.excluded_resource_group_names :
    "${data.azurerm_subscription.current.id}/resourceGroups/${name}"
  ]

  # Staged rollout. false suspends enforcement while keeping one definition,
  # one assignment and one compliance signal; true blocks non-compliant
  # create and update. No identity block: a Deny effect needs no managed
  # identity, so this assignment requests none and sets no location.
  enforce = var.enforce_policy
}

# The Terraform state storage account is reachable from the internet by
# design: a private endpoint on it would require self-hosted CI runners,
# which this project has deliberately not adopted. rg-ztlz-tfstate holds
# only that account. It is exempt from the public-network-access Deny ONLY
# (by reference id), and stays subject to every other policy the baseline
# grows to include.
resource "azurerm_resource_group_policy_exemption" "state_public_network" {
  name                 = "${var.prefix}-tfstate-public-network-waiver"
  resource_group_id    = data.azurerm_resource_group.state.id
  policy_assignment_id = azurerm_subscription_policy_assignment.baseline.id
  exemption_category   = "Waiver"

  policy_definition_reference_ids = ["deny-public-network-access"]

  display_name = "State account: public network access waiver"
  description  = "rg-ztlz-tfstate holds only the Terraform state account, which must stay reachable from GitHub-hosted runners over the blob data plane. A private endpoint would require self-hosted runners in the VNet, rejected for this project. Compensating controls: shared key access disabled, AAD-only blob access, CanNotDelete lock. Scoped to the public-network-access definition only, so future baseline policies still apply."
}

###############################################################################
# Remediation: policies that deploy what is missing (DeployIfNotExists)
#
# Kept apart from the baseline on purpose. A DeployIfNotExists policy needs a
# managed identity, and on azurerm 4.81.0 an assignment that has an identity
# must also have a location - and changing location forces a new assignment.
# Adding these to ztlz-baseline would have destroyed and recreated the
# enforcing Deny and its state-account waiver. A second initiative and
# assignment leaves the Deny untouched, and the identity's roles reach only
# the policies that use them.
#
# fileset's "*.json" does not descend into folders, so files in
# policy/definitions/remediate never join the baseline above.
###############################################################################

locals {
  remediate_dir   = "${path.module}/../../../policy/definitions/remediate"
  remediate_files = fileset(local.remediate_dir, "*.json")

  remediate_definitions = {
    for f in local.remediate_files :
    trimsuffix(f, ".json") => jsondecode(file("${local.remediate_dir}/${f}"))
  }

  # Every role any remediation definition declares, granted once each and
  # keyed by its GUID. Read from the definitions themselves so the grants
  # cannot drift from what the policies ask for: Azure does not update an
  # identity's roles when a definition's roleDefinitionIds change.
  remediate_role_ids = {
    for r in distinct(flatten([
      for d in local.remediate_definitions :
      d.properties.policyRule.then.details.roleDefinitionIds
    ])) : basename(r) => r
  }
}

resource "azurerm_policy_definition" "remediate" {
  for_each = local.remediate_definitions

  name         = each.key
  policy_type  = "Custom"
  mode         = lookup(each.value.properties, "mode", "All")
  display_name = each.value.properties.displayName
  description  = each.value.properties.description

  metadata    = jsonencode(each.value.properties.metadata)
  parameters  = jsonencode(each.value.properties.parameters)
  policy_rule = jsonencode(each.value.properties.policyRule)
}

resource "azurerm_policy_set_definition" "remediate" {
  name         = "${var.prefix}-remediate"
  policy_type  = "Custom"
  display_name = "${var.prefix} remediation"

  dynamic "policy_definition_reference" {
    for_each = azurerm_policy_definition.remediate
    content {
      policy_definition_id = policy_definition_reference.value.id
      reference_id         = policy_definition_reference.key

      # A remediation definition that sends logs somewhere takes the
      # destination as logAnalyticsWorkspaceId. It is filled in here, once,
      # from the platform module, instead of being typed into each JSON file.
      parameter_values = contains(keys(local.remediate_definitions[policy_definition_reference.key].properties.parameters), "logAnalyticsWorkspaceId") ? jsonencode({
        logAnalyticsWorkspaceId = { value = var.log_analytics_workspace_id }
      }) : null
    }
  }
}

# The identity remediation deployments run as. User-assigned rather than
# system-assigned, so it exists - and holds its roles - before the assignment
# that uses it, instead of being created by the assignment and granted
# afterwards.
resource "azurerm_user_assigned_identity" "policy" {
  name                = "id-${var.prefix}-policy"
  location            = var.location
  resource_group_name = var.platform_resource_group_name
  tags                = var.tags
}

# An assignment created through the API, which is what Terraform uses, is not
# granted its definitions' roles automatically the way a portal-created one
# is. Granted here, at the assignment's own scope.
resource "azurerm_role_assignment" "policy_remediation" {
  for_each = local.remediate_role_ids

  scope              = data.azurerm_subscription.current.id
  role_definition_id = "${data.azurerm_subscription.current.id}${each.value}"
  principal_id       = azurerm_user_assigned_identity.policy.principal_id

  # Stated rather than left for Azure to infer. Without it the provider looks
  # the principal up in Entra, which fails intermittently for an identity
  # created seconds earlier in the same apply.
  principal_type = "ServicePrincipal"
}

resource "azurerm_subscription_policy_assignment" "remediate" {
  name                 = "${var.prefix}-remediate"
  display_name         = "${var.prefix} remediation"
  subscription_id      = data.azurerm_subscription.current.id
  policy_definition_id = azurerm_policy_set_definition.remediate.id

  # Required by the provider whenever identity is set, and it forces a new
  # assignment if it ever changes - so it is set from the first apply.
  location = var.location

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.policy.id]
  }

  # Same carve-out as the baseline: unrelated projects that share this
  # subscription are not governed.
  not_scopes = [
    for name in var.excluded_resource_group_names :
    "${data.azurerm_subscription.current.id}/resourceGroups/${name}"
  ]

  # One switch for the whole policy layer. While false, DeployIfNotExists
  # still marks resources non-compliant but deploys nothing.
  enforce = var.enforce_policy

  # The roles exist before the first resource can be evaluated against this
  # assignment, so the first remediation deployment cannot fail on a missing
  # grant.
  depends_on = [azurerm_role_assignment.policy_remediation]
}
