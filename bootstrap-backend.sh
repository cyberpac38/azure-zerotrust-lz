#!/usr/bin/env bash
set -euo pipefail

# Terraform cannot create its own state backend. This runs once, by hand.
# Everything here lives in a resource group that is never destroyed and
# never has policy applied to it.

LOCATION="${1:?usage: ./bootstrap-backend.sh <azure-region>}"
SUFFIX="$(openssl rand -hex 3)"
RG="rg-ztlz-tfstate"
SA="stztlztfstate${SUFFIX}"

echo "Creating $RG and $SA in $LOCATION"

az group create -n "$RG" -l "$LOCATION" -o none

az storage account create \
  -n "$SA" -g "$RG" -l "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  -o none

# Entra auth rather than account keys: there is no key to leak or rotate.
az storage container create \
  -n tfstate --account-name "$SA" --auth-mode login -o none

# Versioning turns a corrupted state file into an inconvenience.
az storage account blob-service-properties update \
  --account-name "$SA" -g "$RG" --enable-versioning true -o none

# Storage Blob Data Contributor is a DATA-plane role. Owner on the
# subscription does not imply it.
ME="$(az ad signed-in-user show --query id -o tsv)"
SA_ID="$(az storage account show -n "$SA" -g "$RG" --query id -o tsv)"
az role assignment create \
  --assignee "$ME" --role "Storage Blob Data Contributor" \
  --scope "$SA_ID" -o none

az lock create --name no-delete --lock-type CanNotDelete -g "$RG" -o none

echo
echo "DONE. Put this in infra/providers.tf:"
echo "  storage_account_name = \"$SA\""
