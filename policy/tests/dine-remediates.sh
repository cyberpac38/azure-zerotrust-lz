#!/usr/bin/env bash
# Runbook steps 7.4 and 7.2. Proves the DeployIfNotExists policy fixes a NEW
# Key Vault, then shows the loose copy calling a vault with no audit logs
# compliant.
#
#   1. Creates one Key Vault in rg-ztlz-shared (public network access
#      Disabled, so the baseline Deny allows it; 7-day soft delete) and, at
#      once, a decoy diagnostic setting that sends metrics only - no logs.
#   2. Step 7.4: waits for the tight policy to deploy 'to-platform-law' (it
#      evaluates 10 minutes after the vault is created) and checks that the
#      setting sends AuditEvent to the platform workspace.
#   3. Step 7.2: deletes 'to-platform-law', forces a compliance scan, and
#      reads the vault's state under both policies. The vault is left with
#      only the decoy and no audit logs anywhere, so the tight policy must
#      say NonCompliant and the loose one Compliant.
#
# A trap removes the settings, deletes the vault and purges it, pass or fail.
# Takes up to about an hour. Costs a fraction of a cent.
#
# Exit codes: 0 PASS | 1 FAIL (a policy did not behave as designed) |
#             2 INCONCLUSIVE (stopped for a reason that is not the policy).
set -euo pipefail

RG="rg-ztlz-shared"
LOCATION="eastus"
LAW_RG="rg-ztlz-platform"
LAW_NAME="log-ztlz-platform"
ASSIGNMENT="ztlz-remediate"
TIGHT_REF="dine-diagnostic-settings"
LOOSE_REF="dine-diagnostic-settings-loose"
TIGHT_SETTING="to-platform-law"
DECOY_SETTING="decoy-metrics-only"
DEPLOY_WAIT_MIN=30
STATE_WAIT_MIN=30
DECOY_DEADLINE_S=540 # the decoy must exist before the 10-minute evaluation

CREATED=""
VAULT_ID=""

cleanup() {
  [ -n "$CREATED" ] || return 0
  echo "cleanup: removing diagnostic settings, then deleting and purging $CREATED"
  if [ -n "$VAULT_ID" ]; then
    for s in $(az monitor diagnostic-settings list --resource "$VAULT_ID" --query "[].name" -o tsv 2>/dev/null); do
      az monitor diagnostic-settings delete --name "$s" --resource "$VAULT_ID" -o none 2>/dev/null || true
    done
  fi
  az keyvault delete -n "$CREATED" -g "$RG" -o none 2>/dev/null || true
  if az keyvault purge -n "$CREATED" -l "$LOCATION" -o none 2>/dev/null; then
    echo "cleanup: purged $CREATED"
  else
    echo "cleanup: could not purge $CREATED (purge protection on?); the name stays reserved for 7 days, at no charge"
  fi
}

# setting_check WORKSPACE_ID < setting JSON -> "WS_OK AUDIT_OK" (each yes|no)
# Walks the whole document rather than assuming where az puts workspaceId and
# logs, because that output shape was not measured before this was written.
setting_check() {
  python3 -I -c '
import json, sys
want = sys.argv[1].lower()
doc = json.load(sys.stdin)
ws, logs = [], []
def walk(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "workspaceId" and isinstance(v, str): ws.append(v.lower())
            elif k == "logs" and isinstance(v, list): logs.extend(v)
            walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
walk(doc)
ws_ok = "yes" if ws and all(w == want for w in ws) else "no"
audit = any(isinstance(l, dict) and l.get("category") == "AuditEvent"
            and str(l.get("enabled")).lower() == "true" for l in logs)
print(ws_ok, "yes" if audit else "no")
' "$1"
}

# states_since EPOCH < policy-state JSON -> "TIGHT LOOSE" (lowercase states,
# "-" where no record newer than EPOCH exists for that reference)
states_since() {
  python3 -I -c '
import json, sys
from datetime import datetime, timezone
since = int(sys.argv[1]); assignment = sys.argv[2].lower()
refs = {sys.argv[3].lower(): "-", sys.argv[4].lower(): "-"}
best = {}
for r in json.load(sys.stdin):
    if (r.get("policyAssignmentName") or "").lower() != assignment: continue
    ref = (r.get("policyDefinitionReferenceId") or "").lower()
    if ref not in refs: continue
    ts = (r.get("timestamp") or "").replace("Z", "+00:00")
    try:
        t = datetime.fromisoformat(ts)
    except ValueError:
        if "." in ts:
            head, tail = ts.split(".", 1)
            frac = "".join(c for c in tail if c.isdigit())[:6]
            zone = tail[len("".join(c for c in tail if c.isdigit())):] or "+00:00"
            t = datetime.fromisoformat(head + "." + frac.ljust(6, "0") + zone)
        else:
            continue
    if t.tzinfo is None: t = t.replace(tzinfo=timezone.utc)
    if t.timestamp() < since: continue
    if ref not in best or t > best[ref][0]:
        best[ref] = (t, (r.get("complianceState") or "-").lower())
for ref in best: refs[ref] = best[ref][1]
print(refs[sys.argv[3].lower()], refs[sys.argv[4].lower()])
' "$1" "$ASSIGNMENT" "$TIGHT_REF" "$LOOSE_REF"
}

# decide DEPLOYED WS_OK AUDIT_OK TIGHT LOOSE REAPPEARED
#   -> PASS | FAIL_DEPLOY | FAIL_SETTING | REDEPLOYED | FAIL_TRAP | INCONCLUSIVE
# Factored out so it can be tested against synthetic inputs without Azure.
# REDEPLOYED is its own outcome, not a failure: if the tight setting comes
# back after the 7.2 delete, the policy re-deployed it on its own - a
# behaviour not measured before this was written, which would only mean the
# 7.2 demonstration needs a different trigger.
decide() {
  local deployed="$1" ws_ok="$2" audit_ok="$3" tight="$4" loose="$5" reappeared="${6:-no}"
  if [ "$deployed" != "yes" ]; then echo "FAIL_DEPLOY"; return 0; fi
  if [ "$ws_ok" != "yes" ] || [ "$audit_ok" != "yes" ]; then echo "FAIL_SETTING"; return 0; fi
  if [ "$reappeared" = "yes" ]; then echo "REDEPLOYED"; return 0; fi
  if [ "$tight" = "-" ] || [ "$loose" = "-" ] || [ -z "$tight" ] || [ -z "$loose" ]; then echo "INCONCLUSIVE"; return 0; fi
  if [ "$tight" = "noncompliant" ] && [ "$loose" = "compliant" ]; then echo "PASS"; else echo "FAIL_TRAP"; fi
}

main() {
  trap cleanup EXIT
  local name law_id err t0 elapsed i deployed="no" ws_ok="no" audit_ok="no"
  local setting="" tight="-" loose="-" deleted_at verdict reappeared="no"
  name="kv-dine-$(date -u +%m%d%H%M%S)"

  if ! law_id="$(az monitor log-analytics workspace show -g "$LAW_RG" -n "$LAW_NAME" --query id -o tsv 2>&1)"; then
    echo "INCONCLUSIVE: platform workspace $LAW_NAME not readable. Raw error:"; printf '%s\n' "$law_id"; exit 2
  fi

  t0=$(date +%s)
  echo "creating $name in $RG (public network access Disabled, 7-day soft delete)"
  if ! err="$(az keyvault create -n "$name" -g "$RG" -l "$LOCATION" --public-network-access Disabled --retention-days 7 -o none 2>&1)"; then
    echo "INCONCLUSIVE: vault create failed. Raw error:"; printf '%s\n' "$err"; exit 2
  fi
  CREATED="$name"
  VAULT_ID="$(az keyvault show -n "$name" -g "$RG" --query id -o tsv)"
  az keyvault show -n "$name" -g "$RG" \
    --query "{publicNetworkAccess:properties.publicNetworkAccess, purgeProtection:properties.enablePurgeProtection, softDeleteDays:properties.softDeleteRetentionInDays}" -o json

  if ! err="$(az monitor diagnostic-settings create --name "$DECOY_SETTING" --resource "$VAULT_ID" --workspace "$law_id" --metrics '[{"category":"AllMetrics","enabled":true}]' -o none 2>&1)"; then
    echo "INCONCLUSIVE: decoy setting create failed. Raw error:"; printf '%s\n' "$err"; exit 2
  fi
  elapsed=$(($(date +%s) - t0))
  if [ "$elapsed" -ge "$DECOY_DEADLINE_S" ]; then
    echo "INCONCLUSIVE: the decoy took ${elapsed}s, too close to the policy's 10-minute evaluation to trust the 7.2 result"; exit 2
  fi
  echo "decoy '$DECOY_SETTING' in place ${elapsed}s after create (metrics only, no logs)"

  echo "7.4: waiting up to ${DEPLOY_WAIT_MIN} min for the policy to deploy '$TIGHT_SETTING' (it evaluates 10 min after create)"
  for i in $(seq 1 "$DEPLOY_WAIT_MIN"); do
    sleep 60
    if az monitor diagnostic-settings show --name "$TIGHT_SETTING" --resource "$VAULT_ID" -o none 2>/dev/null; then
      deployed="yes"; break
    fi
    echo "  minute $i: not yet"
  done

  if [ "$deployed" = "yes" ]; then
    elapsed=$(($(date +%s) - t0))
    echo "7.4: '$TIGHT_SETTING' appeared ${elapsed}s after the vault was created (checked once a minute). The setting as Azure holds it:"
    setting="$(az monitor diagnostic-settings show --name "$TIGHT_SETTING" --resource "$VAULT_ID" -o json)"
    printf '%s\n' "$setting"
    read -r ws_ok audit_ok < <(printf '%s' "$setting" | setting_check "$law_id")
    echo "7.4: sends to the platform workspace: $ws_ok; AuditEvent enabled: $audit_ok"
    echo "7.4: deployments in $RG (the policy's own deployment is among them):"
    az deployment group list -g "$RG" --query "[].name" -o tsv 2>/dev/null | tail -5 || true
  fi

  if [ "$deployed" = "yes" ] && [ "$ws_ok" = "yes" ] && [ "$audit_ok" = "yes" ]; then
    echo "7.2: deleting '$TIGHT_SETTING' - the vault keeps only the decoy, so its audit logs go nowhere"
    az monitor diagnostic-settings delete --name "$TIGHT_SETTING" --resource "$VAULT_ID" -o none
    deleted_at=$(date +%s)
    echo "7.2: settings now on the vault: $(az monitor diagnostic-settings list --resource "$VAULT_ID" --query "[].name" -o tsv | tr '\n' ' ')"
    echo "7.2: forcing a compliance scan of $RG (this alone can take several minutes)"
    az policy state trigger-scan -g "$RG" -o none 2>/dev/null || echo "  trigger-scan returned an error; polling anyway"
    for i in $(seq 1 "$STATE_WAIT_MIN"); do
      read -r tight loose < <(az policy state list --resource "$VAULT_ID" -o json 2>/dev/null | states_since "$deleted_at")
      echo "  poll $i: tight=$tight loose=$loose (only states evaluated after the delete count)"
      if [ "$tight" != "-" ] && [ "$loose" != "-" ]; then break; fi
      sleep 60
    done
    if az monitor diagnostic-settings show --name "$TIGHT_SETTING" --resource "$VAULT_ID" -o none 2>/dev/null; then reappeared="yes"; fi
    echo "7.2: settings on the vault at the verdict: $(az monitor diagnostic-settings list --resource "$VAULT_ID" --query "[].name" -o tsv | tr '\n' ' ')"
  fi

  verdict="$(decide "$deployed" "$ws_ok" "$audit_ok" "$tight" "$loose" "$reappeared")"
  case "$verdict" in
    PASS)
      echo "PASS: 7.4 - a new vault was given '$TIGHT_SETTING', sending AuditEvent to $LAW_NAME, by the policy alone."
      echo "PASS: 7.2 - with only a metrics decoy left, the tight policy reads NonCompliant and the loose one reads Compliant: the loose check calls a vault with no audit logs compliant."
      exit 0 ;;
    FAIL_DEPLOY)
      echo "FAIL: the policy did not deploy '$TIGHT_SETTING' within ${DEPLOY_WAIT_MIN} minutes of the vault's creation."
      echo "      Check the assignment's identity roles (step 7.3) and the activity log of $RG for a failed policy deployment."
      exit 1 ;;
    FAIL_SETTING)
      echo "FAIL: '$TIGHT_SETTING' exists but does not send AuditEvent to $LAW_NAME (workspace match: $ws_ok, AuditEvent: $audit_ok)."
      exit 1 ;;
    REDEPLOYED)
      echo "OBSERVED: 7.4 passed. After '$TIGHT_SETTING' was deleted, the policy deployed it again on its own (tight=$tight loose=$loose)."
      echo "          That is a finding, not a failure: the 7.2 demonstration needs a trigger other than deleting the setting."
      exit 2 ;;
    FAIL_TRAP)
      echo "FAIL: after the delete, expected tight=noncompliant and loose=compliant; got tight=$tight loose=$loose."
      exit 1 ;;
    INCONCLUSIVE)
      echo "INCONCLUSIVE: the compliance states had not refreshed after ${STATE_WAIT_MIN} minutes (tight=$tight loose=$loose). 7.4 passed; re-run for 7.2."
      exit 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
