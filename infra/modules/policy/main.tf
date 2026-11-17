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
