###############################################################################
# infra/outputs.tf
#
# Module outputs are not root outputs. Anything consumed from outside
# terraform - up.sh, step 3.9, later phases - must be re-exported here.
###############################################################################

output "hub_vnet_id" {
  description = "Hub VNet resource ID. The private DNS phase links zones to it."
  value       = module.network.hub_vnet_id
}

output "spoke_vnet_ids" {
  description = "Spoke VNet resource IDs by spoke key."
  value       = module.network.spoke_vnet_ids
}

output "spoke_workload_subnet_ids" {
  description = "Workload subnet IDs by spoke key. The 3.8 route verification VM goes here."
  value       = module.network.spoke_workload_subnet_ids
}

output "spoke_privatelink_subnet_ids" {
  description = "Private endpoint subnet IDs by spoke key. The private endpoints phase places them here."
  value       = module.network.spoke_privatelink_subnet_ids
}

output "firewall_policy_id" {
  description = "Firewall policy ID. Exists whether or not a firewall does."
  value       = module.network.firewall_policy_id
}

output "workload_nsg_ids" {
  description = "Workload NSG IDs by spoke key. A later phase adds application allow rules to these."
  value       = module.network.workload_nsg_ids
}

# Read by up.sh and by step 3.9. null when firewall_enabled is false.
output "firewall_private_ip" {
  description = "Private IP of the firewall, or null when firewall_enabled is false."
  value       = module.network.firewall_private_ip
}

output "private_dns_zone_ids" {
  description = "Private DNS zone resource IDs by zone name. The private endpoints phase passes the Key Vault zone ID into its private endpoint's DNS zone group; without that group the endpoint exists, routing works, and nothing resolves to it."
  value       = module.dns.zone_ids
}

output "private_dns_zone_names" {
  description = "Zone names created."
  value       = module.dns.zone_names
}

output "private_dns_link_count" {
  description = "Number of virtual network links created. Check against the plan: 6 zones times 3 VNets is 18."
  value       = module.dns.link_count
}
