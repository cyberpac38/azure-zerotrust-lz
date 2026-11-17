###############################################################################
# infra/modules/platform/main.tf
#
# Shared platform services that belong to no single spoke: the platform
# resource group and the Log Analytics workspace. The DeployIfNotExists
# policies send Key Vault audit logs here, and the observability phase and the
# NXDOMAIN alert (runbook step 4.5) are built on the same workspace.
###############################################################################

resource "azurerm_resource_group" "platform" {
  name     = "rg-${var.prefix}-platform"
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "platform" {
  name                = "log-${var.prefix}-platform"
  location            = azurerm_resource_group.platform.location
  resource_group_name = azurerm_resource_group.platform.name
  tags                = var.tags

  # Pay per GB taken in, with no commitment tier. 30 days is the shortest
  # retention the provider accepts.
  sku               = "PerGB2018"
  retention_in_days = 30
}

###############################################################################
# Outputs
###############################################################################

output "resource_group_name" {
  description = "Name of the platform resource group. The policy module creates its remediation identity here."
  value       = azurerm_resource_group.platform.name
}

output "log_analytics_workspace_id" {
  description = "Resource ID of the platform Log Analytics workspace. The remediation initiative passes it to every policy that takes logAnalyticsWorkspaceId."
  value       = azurerm_log_analytics_workspace.platform.id
}
