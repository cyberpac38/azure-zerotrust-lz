#!/usr/bin/env bash
###############################################################################
# up.sh - bring the hourly-billed layer online for one work session.
#
# WHY THIS EXISTS: Azure Firewall bills by the hour whether or not traffic
# passes it, so the estate is built to be absent between sessions. This script
# and down.sh make that mechanical rather than a matter of remembering.
#
# WHAT REPLACED -target. The previous version ran
#   terraform apply -auto-approve -target=module.network
# A -target address that matches nothing prints "No changes" and exits 0, so
# the script could not tell "built it" from "did nothing" - and a targeted
# apply silently skips anything outside the address. The firewall's existence
# is now a variable, so this applies the WHOLE configuration with
# firewall_enabled=true and there is no target address to get wrong.
#
# That trade has a consequence, and section 5 is the answer to it: applying
# the whole configuration means an unrelated change sitting unapplied in main
# would also get applied, here, unreviewed. So this script plans first and
# REFUSES to apply unless every single planned change is one of the three it
# expects. It cannot be used to push anything else.
###############################################################################
set -euo pipefail

###############################################################################
# 1. Right shell
#
# WSL cannot run terraform: Go binaries resolve AAAA records and attempt IPv6,
# and WSL has only a link-local address with no IPv6 route. The failure reads
# as "network is unreachable" or a misleading "no such host".
#
# A sturdier marker than the username would be Cloud Shell's own environment
# variable. Measure it once in Cloud Shell and swap it in if you prefer:
#   echo "${AZUREPS_HOST_ENVIRONMENT:-unset}"
###############################################################################
if [ "$(whoami)" != "martin" ]; then
  cat >&2 <<'MSG'
REFUSING TO RUN: this is not Azure Cloud Shell.

Terraform cannot reach Azure from WSL - Go binaries attempt IPv6 and WSL has
no IPv6 route. Open Azure Cloud Shell, clone the repo fresh, and run this
there. WSL is for editing, git, az and gh.
MSG
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT/infra"

###############################################################################
# 2. Pinned terraform binary
#
# Cloud Shell's bundled terraform version is NOT stable - measured 1.17.0 one
# morning and 1.16.0 the same afternoon, because Microsoft upgrades the image
# without notice. providers.tf pins required_version exactly, so a mismatched
# shell refuses to run, which is correct. This fetches the pinned version
# rather than trusting the image.
#
# The version is READ FROM providers.tf, not written here. There are already
# three places that name it (providers.tf and two setup-terraform steps); a
# fourth and fifth hardcoded copy in these scripts would be two more things to
# miss on a version bump.
###############################################################################
TF_VER="$(sed -n 's/.*required_version[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' providers.tf | head -1)"
if [ -z "$TF_VER" ]; then
  echo "ABORT: could not read required_version from infra/providers.tf" >&2
  exit 1
fi

TF_DIR="${TMPDIR:-/tmp}/tf-${TF_VER}"
if [ ! -x "${TF_DIR}/terraform" ]; then
  echo "==> fetching terraform ${TF_VER} (Cloud Shell's bundled version is not trusted)"
  mkdir -p "$TF_DIR"
  (
    cd "$TF_DIR"
    # Checksum-verified, same discipline as the gitleaks download in CI. An
    # unverified binary that plans your infrastructure is not a small thing.
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
# 3. Auth
#
# azurerm 4.x REQUIRES a subscription id - either on the provider block or in
# ARM_SUBSCRIPTION_ID. providers.tf does not set it (deliberately: the value
# differs per environment), and deploy.yml supplies it from a repository
# variable. Nothing supplies it in Cloud Shell, so this does, from the
# session's own az login rather than from a hardcoded GUID.
###############################################################################
ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
export ARM_SUBSCRIPTION_ID
export ARM_USE_AZUREAD=true
echo "==> subscription ${ARM_SUBSCRIPTION_ID}"

###############################################################################
# 4. Init
#
# Cloud Shell starts from a fresh clone each session, so .terraform/ never
# exists and init is not optional.
###############################################################################
echo "==> terraform init"
terraform init -input=false -lock-timeout=5m

###############################################################################
# 5. Plan, and refuse anything that is not the firewall
#
# The plan file and its JSON go to a temp directory OUTSIDE the repository and
# are deleted on exit. This repository is public, and so are its Actions logs;
# a plan file must never be in a position to be committed by accident.
#
# The guard allowlists by TYPE AND ACTION, not by counting changes. A count
# guard passes if terraform plans to delete one VNet and create one firewall.
# This one names every planned change that is not exactly a firewall create, a
# public IP create, or a route table update - and refuses on any of them.
###############################################################################
PLAN_DIR="$(mktemp -d)"
trap 'rm -rf "$PLAN_DIR"' EXIT

echo "==> planning with firewall_enabled=true"
terraform plan -input=false -lock-timeout=5m \
  -var firewall_enabled=true \
  -out="${PLAN_DIR}/session.tfplan"

terraform show -json "${PLAN_DIR}/session.tfplan" >"${PLAN_DIR}/session.json"

UNEXPECTED="$(jq -r '
  [ .resource_changes[]
    | select(.change.actions != ["no-op"] and .change.actions != ["read"])
    | select(
        ((.type == "azurerm_firewall"   and .change.actions == ["create"]) or
         (.type == "azurerm_public_ip"  and .change.actions == ["create"]) or
         (.type == "azurerm_route_table" and .change.actions == ["update"])) | not
      )
    | "  \(.address)  ->  \(.change.actions | join(","))"
  ] | .[]' "${PLAN_DIR}/session.json")"

if [ -n "$UNEXPECTED" ]; then
  cat >&2 <<MSG

REFUSING TO APPLY: the plan contains changes this script does not bring up.

$UNEXPECTED

up.sh only ever creates the firewall and its public IP and updates the spoke
route tables. Anything else means main has unapplied changes, or state has
drifted. Apply it through a pull request where it gets reviewed and scanned,
not through this script.
MSG
  exit 1
fi

FW_CREATE="$(jq '[.resource_changes[]
  | select(.type == "azurerm_firewall" and .change.actions == ["create"])] | length' \
  "${PLAN_DIR}/session.json")"

###############################################################################
# 6. Apply
###############################################################################
if [ "$FW_CREATE" -eq 0 ]; then
  echo "==> no firewall to create - it is already up. Skipping apply, verifying anyway."
  ELAPSED="n/a"
else
  echo "==> applying"
  START="$(date +%s)"
  terraform apply -input=false -lock-timeout=5m "${PLAN_DIR}/session.tfplan"
  ELAPSED="$(( $(date +%s) - START ))s"
fi

###############################################################################
# 7. Verify from the failure's perspective
#
# Not "did terraform exit 0" but "what would a half-working result look like,
# and can this check see it".
#
# Two distinct failures are possible and they look identical from terraform's
# exit code: a firewall that exists but is not Succeeded, and a firewall that
# is up while the route tables still point at None - which would mean the
# spokes have no egress at all and the session is dead before it starts. The
# old script could only see the first.
###############################################################################
echo "==> verifying against Azure, not against terraform's exit code"

FW_STATE="$(az network firewall show -n "afw-ztlz" -g "rg-ztlz-hub" \
  --query provisioningState -o tsv 2>/dev/null || true)"
if [ "$FW_STATE" != "Succeeded" ]; then
  echo "FAILED: afw-ztlz in rg-ztlz-hub is '${FW_STATE:-absent}', not Succeeded." >&2
  exit 1
fi

PRIV="$(terraform output -raw firewall_private_ip)"
if [ -z "$PRIV" ] || [ "$PRIV" = "null" ]; then
  echo "FAILED: terraform reports no firewall private IP while Azure reports Succeeded." >&2
  exit 1
fi

BAD_ROUTES=0
while read -r RG RT; do
  [ -z "$RG" ] && continue
  read -r HOP IP <<<"$(az network route-table route show \
    -g "$RG" --route-table-name "$RT" -n "default-egress" \
    --query "[nextHopType, nextHopIpAddress]" -o tsv 2>/dev/null || echo "MISSING -")"
  if [ "$HOP" != "VirtualAppliance" ] || [ "$IP" != "$PRIV" ]; then
    echo "FAILED: ${RT} default-egress is ${HOP} ${IP}, expected VirtualAppliance ${PRIV}" >&2
    BAD_ROUTES=$((BAD_ROUTES + 1))
  fi
done < <(az network route-table list \
  --query "[?starts_with(name,'rt-ztlz-')].[resourceGroup,name]" -o tsv)

if [ "$BAD_ROUTES" -ne 0 ]; then
  echo "The firewall is UP and BILLING but ${BAD_ROUTES} spoke route table(s) do not point at it." >&2
  echo "Run ./down.sh - you are paying for a firewall nothing routes through." >&2
  exit 1
fi

###############################################################################
# 8. Report
###############################################################################
cat <<MSG

Firewall UP at $(date -u +%Y-%m-%dT%H:%MZ)
  private IP     ${PRIV}
  spoke egress   0.0.0.0/0 -> VirtualAppliance ${PRIV}  (verified on every rt-ztlz-*)
  apply took     ${ELAPSED}

The meter is running. The ~\$1.25/hr figure in docs/ is third-party, Central
US, July 2026, and directional only - confirm your region in Cost analysis
before quoting it anywhere.

Log the start time in docs/cost-sessions.md. Run ./down.sh when you stop.
The nightly teardown at 04:23 UTC is the backstop, not the plan.
MSG
