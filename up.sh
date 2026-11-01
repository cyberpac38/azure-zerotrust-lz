#!/usr/bin/env bash
# up.sh - bring the hourly-billed layer online for a work session.
#
# WHY THIS EXISTS: Azure Firewall bills by the hour whether or not traffic
# passes it, so the estate is built to be absent between sessions. This script
# is half of the pair that makes that mechanical rather than a matter of
# remembering.
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/infra"

FW_RG="rg-ztlz-hub"
FW_NAME="afw-ztlz"

# Cloud Shell runs with no mounted storage, so every session is a fresh clone
# and .terraform/ never exists. init is not optional here.
echo "==> terraform init"
terraform init -input=false

echo "==> apply module.network"
terraform apply -auto-approve -target=module.network

# Verification written from the FAILURE's perspective. A -target address that
# matches nothing prints "No changes" and exits 0, so terraform's exit code
# cannot distinguish "built it" from "did nothing". Ask Azure instead.
echo "==> verifying against Azure, not against terraform's exit code"
STATE=$(az network firewall show -n "$FW_NAME" -g "$FW_RG" \
          --query provisioningState -o tsv 2>/dev/null || true)

if [ "$STATE" != "Succeeded" ]; then
  echo
  echo "FAILED: no firewall '$FW_NAME' in '$FW_RG' reporting Succeeded"
  echo "        (got '${STATE:-absent}')."
  echo "The apply reported success without producing a firewall. Most likely"
  echo "infra/main.tf does not declare module \"network\" yet - that is step 3.7."
  exit 1
fi

PRIV=$(az network firewall show -n "$FW_NAME" -g "$FW_RG" \
         --query "ipConfigurations[0].privateIPAddress" -o tsv)

echo
echo "Firewall UP at $(date -u +%Y-%m-%dT%H:%MZ)   private IP $PRIV"
echo "Meter running. ~\$1.25/hr is a third-party figure (Central US, Jul 2026),"
echo "directional only - confirm your region in Cost analysis before quoting it."
echo "Log the start time in docs/cost-sessions.md. Run ./down.sh when you stop."
