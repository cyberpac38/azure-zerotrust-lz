#!/usr/bin/env bash
# down.sh - destroy ONLY the hourly-billed pieces.
#
# WHY THIS EXISTS: the VNets, subnets, peerings and route tables cost nothing
# at rest, so they stay and the next up.sh is fast. Only the firewall and its
# public IP are torn down.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/infra"

echo "==> terraform init"
terraform init -input=false

# The destroy is PLANNED first and printed, not fired blind. Reason: a
# targeted destroy also removes resources that depend on the target, and the
# spoke route tables reference the firewall's private IP. Exactly which
# resources that pulls in has not been measured on this estate yet, so the
# first run of this script is where you find out - from a plan, not from a
# surprise. The filename matches *.tfplan in .gitignore on purpose.
echo "==> planning the teardown"
terraform plan -destroy \
  -target=module.network.azurerm_firewall.main \
  -target=module.network.azurerm_public_ip.firewall \
  -out=teardown.tfplan

echo "==> what that plan will remove"
terraform show -no-color teardown.tfplan | grep -E '^  # |^Plan:' || true

echo "==> applying the teardown plan"
terraform apply teardown.tfplan
rm -f teardown.tfplan

# Same failure-perspective check as up.sh, inverted: prove the meter is off by
# asking Azure. If terraform tore down nothing because an address was wrong,
# this is what catches it.
echo "==> verifying the meter is actually stopped"
FW_COUNT=$(az network firewall list --query "length(@)" -o tsv)

if [ "$FW_COUNT" != "0" ]; then
  echo
  echo "FAILED: $FW_COUNT firewall(s) still present after teardown:"
  az network firewall list --query "[].{name:name,rg:resourceGroup}" -o table
  echo "The meter is STILL RUNNING. Either a -target address no longer matches"
  echo "the state, or a firewall exists outside terraform's state."
  exit 1
fi

echo
echo "Firewall DOWN at $(date -u +%Y-%m-%dT%H:%MZ) - meter stopped"
echo
echo "Unattached public IPs (these keep billing after the firewall goes):"
az network public-ip list \
  --query "[?ipConfiguration==null].{name:name,rg:resourceGroup,sku:sku.name}" \
  -o table
echo "Reported, not deleted - the nightly workflow sweeps them once it exists."
echo "Record the session's hours in docs/cost-sessions.md."
