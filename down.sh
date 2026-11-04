#!/usr/bin/env bash
###############################################################################
# down.sh - stop the meter.
#
# WHY THIS EXISTS: the VNets, subnets, peerings and route tables cost nothing
# at rest, so they stay and the next up.sh is fast. Only the firewall and its
# public IP are hourly-billed, and only those come down.
#
# WHAT REPLACED -target. The previous version ran a targeted destroy against
#   module.network.azurerm_firewall.main
#   module.network.azurerm_public_ip.firewall
# and its own comment flagged the open question: a targeted destroy also
# removes resources that DEPEND on the target, the spoke route tables
# reference the firewall's private IP, and exactly what that pulls in had
# never been measured. That question no longer exists. The firewall's
# existence is a variable, so this applies the whole configuration with
# firewall_enabled=false; the route tables survive and their next hop becomes
# "None", which DROPS spoke egress rather than letting Azure's default system
# route restore unfiltered internet access.
#
# Section 5 is the guard that makes applying the whole configuration safe: it
# refuses to apply unless every planned change is a firewall delete, a public
# IP delete, or a route table update. A drifted state cannot use this script
# to destroy the estate.
###############################################################################
set -euo pipefail

###############################################################################
# 1. Right shell
###############################################################################
if [ "$(whoami)" != "martin" ]; then
  cat >&2 <<'MSG'
REFUSING TO RUN: this is not Azure Cloud Shell.

Terraform cannot reach Azure from WSL - Go binaries attempt IPv6 and WSL has
no IPv6 route. Open Azure Cloud Shell, clone the repo fresh, and run this
there.

IF YOU ARE TRYING TO STOP THE METER RIGHT NOW and cannot get to Cloud Shell,
az works from WSL and the nightly workflow uses exactly this:
  az network firewall delete --ids \
    $(az network firewall list --query "[].id" -o tsv)
That leaves terraform state drifted, which the next up.sh refreshes away.
MSG
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT/infra"

###############################################################################
# 2. Pinned terraform binary - read from providers.tf, not hardcoded here
###############################################################################
TF_VER="$(sed -n 's/.*required_version[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' providers.tf | head -1)"
if [ -z "$TF_VER" ]; then
  echo "ABORT: could not read required_version from infra/providers.tf" >&2
  exit 1
fi

TF_DIR="${TMPDIR:-/tmp}/tf-${TF_VER}"
if [ ! -x "${TF_DIR}/terraform" ]; then
  echo "==> fetching terraform ${TF_VER}"
  mkdir -p "$TF_DIR"
  (
    cd "$TF_DIR"
    curl -fsSL -O "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_linux_amd64.zip"
    curl -fsSL -O "https://releases.hashicorp.com/terraform/${TF_VER}/terraform_${TF_VER}_SHA256SUMS"
    grep " terraform_${TF_VER}_linux_amd64.zip\$" "terraform_${TF_VER}_SHA256SUMS" | sha256sum -c -
    unzip -oq "terraform_${TF_VER}_linux_amd64.zip" terraform
  )
fi
export PATH="${TF_DIR}:${PATH}"

RUNNING="$(terraform version -json | jq -r .terraform_version)"
if [ "$RUNNING" != "$TF_VER" ]; then
  echo "ABORT: terraform on PATH is ${RUNNING}, providers.tf pins ${TF_VER}" >&2
  exit 1
fi
echo "==> terraform ${RUNNING}"

###############################################################################
# 3. Auth - azurerm 4.x requires a subscription id and nothing supplies one in
#    Cloud Shell
###############################################################################
ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export ARM_SUBSCRIPTION_ID
export ARM_USE_AZUREAD=true

###############################################################################
# 4. Init
###############################################################################
echo "==> terraform init"
terraform init -input=false -lock-timeout=5m

###############################################################################
# 5. Plan, and refuse to destroy anything but the firewall
#
# This is the most important guard in either script. Applying the whole
# configuration is what removed the -target defect, but it also means a
# drifted or tampered state could in principle plan to destroy VNets,
# peerings or resource groups. The allowlist below makes that structurally
# impossible: anything other than a firewall delete, a public IP delete or a
# route table update aborts before a single resource is touched.
###############################################################################
PLAN_DIR="$(mktemp -d)"
trap 'rm -rf "$PLAN_DIR"' EXIT

echo "==> planning with firewall_enabled=false"
terraform plan -input=false -lock-timeout=5m \
  -var firewall_enabled=false \
  -out="${PLAN_DIR}/teardown.tfplan"

terraform show -json "${PLAN_DIR}/teardown.tfplan" >"${PLAN_DIR}/teardown.json"

echo "==> what this plan will change"
jq -r '.resource_changes[]
  | select(.change.actions != ["no-op"] and .change.actions != ["read"])
  | "  \(.change.actions | join(",") | ascii_upcase)  \(.address)"' \
  "${PLAN_DIR}/teardown.json"

UNEXPECTED="$(jq -r '
  [ .resource_changes[]
    | select(.change.actions != ["no-op"] and .change.actions != ["read"])
    | select(
        ((.type == "azurerm_firewall"    and .change.actions == ["delete"]) or
         (.type == "azurerm_public_ip"   and .change.actions == ["delete"]) or
         (.type == "azurerm_route_table" and .change.actions == ["update"])) | not
      )
    | "  \(.address)  ->  \(.change.actions | join(","))"
  ] | .[]' "${PLAN_DIR}/teardown.json")"

if [ -n "$UNEXPECTED" ]; then
  cat >&2 <<MSG

REFUSING TO APPLY: the plan touches resources this script does not tear down.

$UNEXPECTED

down.sh only ever deletes the firewall and its public IP and updates the
spoke route tables. Nothing has been changed. If the firewall is billing and
you need it gone now, use the az command in the WSL message at the top of
this script, then investigate the drift separately.
MSG
  exit 1
fi

###############################################################################
# 6. Apply
###############################################################################
echo "==> applying the teardown plan"
START="$(date +%s)"
terraform apply -input=false -lock-timeout=5m "${PLAN_DIR}/teardown.tfplan"
ELAPSED="$(( $(date +%s) - START ))s"

###############################################################################
# 7. Verify the meter is actually stopped
#
# Detection is deliberately WIDER than action. The plan above could only touch
# resources terraform manages in this configuration; this check looks at the
# whole subscription, because a firewall created outside terraform bills
# exactly the same as one inside it.
#
# Then the inverse of up.sh's route check: a teardown that removed the
# firewall but left the route tables pointing at a now-dead private IP would
# be a silent blackhole that looks nothing like a cost problem.
###############################################################################
echo "==> verifying"

FW_COUNT="$(az network firewall list --query "length(@)" -o tsv)"
if [ "$FW_COUNT" != "0" ]; then
  az network firewall list --query "[].{name:name,rg:resourceGroup}" -o table
  echo "FAILED: ${FW_COUNT} firewall(s) still present. THE METER IS STILL RUNNING." >&2
  exit 1
fi

BAD_ROUTES=0
while read -r RG RT; do
  [ -z "$RG" ] && continue
  HOP="$(az network route-table route show \
    -g "$RG" --route-table-name "$RT" -n "default-egress" \
    --query nextHopType -o tsv 2>/dev/null || echo MISSING)"
  if [ "$HOP" != "None" ]; then
    echo "FAILED: ${RT} default-egress is ${HOP}, expected None" >&2
    BAD_ROUTES=$((BAD_ROUTES + 1))
  fi
done < <(az network route-table list \
  --query "[?starts_with(name,'rt-ztlz-')].[resourceGroup,name]" -o tsv)

if [ "$BAD_ROUTES" -ne 0 ]; then
  echo "The firewall is gone but ${BAD_ROUTES} route table(s) still point at it." >&2
  echo "Spoke egress is blackholed at a dead IP rather than cleanly dropped." >&2
  exit 1
fi

###############################################################################
# 8. Report
###############################################################################
echo
echo "Firewall DOWN at $(date -u +%Y-%m-%dT%H:%MZ) - meter stopped (destroy took ${ELAPSED})"
echo "  spoke egress   0.0.0.0/0 -> None  (verified on every rt-ztlz-*)"
echo
echo "Unattached public IPs anywhere in the subscription - these keep billing:"
az network public-ip list \
  --query "[?ipConfiguration==null].{name:name,rg:resourceGroup,sku:sku.name}" -o table
echo "Reported, not deleted. The nightly workflow sweeps the ones in rg-ztlz-*."
echo
echo "Record this session's hours in docs/cost-sessions.md."
