#!/usr/bin/env bash
# Attempts to create a Storage account with public network access enabled.
# Under the enforcing Deny this MUST be refused with RequestDisallowedByPolicy
# naming the ztlz-baseline assignment. Under enforcement-off it will succeed;
# the trap deletes whatever got created so the test leaves nothing behind.
#
# Exit codes: 0 PASS (refused by policy) | 1 FAIL (not refused) |
#             2 INCONCLUSIVE (failed for a non-policy reason).
set -euo pipefail

RG="rg-ztlz-workload"
ASSIGNMENT="ztlz-baseline"
CREATED=""

cleanup() {
  if [ -n "$CREATED" ]; then
    echo "cleanup: deleting $CREATED"
    az storage account delete -n "$CREATED" -g "$RG" --yes -o none 2>/dev/null || true
  fi
}

# classify RC STDERR -> PASS | PASS_OTHER | FAIL | INCONCLUSIVE
# Factored out so it can be tested against synthetic payloads without Azure.
classify() {
  local rc="$1" err="$2"
  if [ "$rc" -eq 0 ]; then echo "FAIL"; return 0; fi
  if printf '%s' "$err" | grep -q 'RequestDisallowedByPolicy'; then
    if printf '%s' "$err" | grep -q "$ASSIGNMENT"; then echo "PASS"; else echo "PASS_OTHER"; fi
  else
    echo "INCONCLUSIVE"
  fi
}

main() {
  trap cleanup EXIT
  local name="sttestdeny$RANDOM" err rc verdict
  err="$(az storage account create -n "$name" -g "$RG" -l eastus --sku Standard_LRS --public-network-access Enabled -o none 2>&1)" && rc=0 || rc=$?
  [ "$rc" -eq 0 ] && CREATED="$name"
  verdict="$(classify "$rc" "$err")"
  case "$verdict" in
    PASS)         echo "PASS: deployment refused by policy assignment '$ASSIGNMENT' (RequestDisallowedByPolicy). Evidence:"; printf '%s\n' "$err"; exit 0 ;;
    PASS_OTHER)   echo "PASS (caveat): refused by policy, but the error did not name '$ASSIGNMENT'. Raw error:"; printf '%s\n' "$err"; exit 0 ;;
    FAIL)         echo "FAIL: deployment was NOT refused -- policy is not enforcing, or does not cover this resource."; exit 1 ;;
    INCONCLUSIVE) echo "INCONCLUSIVE: creation failed, but NOT by policy. Raw error:"; printf '%s\n' "$err"; exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
