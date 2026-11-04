#!/usr/bin/env bash
#
# verify-routes.sh - runbook step 3.8
#
# Proves the 0.0.0.0/0 user-defined route is real and is actually applied to
# each spoke's snet-workload, by reading the effective route table of a running
# VM in that subnet. Microsoft returns effective-route output only for a VM in
# the running state, so a real VM is unavoidable.
#
# RUN IT TWICE:
#   1. with no firewall deployed      -> expects 0.0.0.0/0 -> None
#   2. after up.sh (in Cloud Shell)   -> expects 0.0.0.0/0 -> VirtualAppliance
#                                        at the firewall's private IP
# The script works out which case it is in by counting firewalls, so there is
# no flag to forget.
#
# WHAT IT CAN TOUCH: it creates a resource group named rg-ztlz-verify and
# creates VMs, NICs and disks inside that group only, and deletes that whole
# group on exit - including on error and on Ctrl-C. Every reference to
# rg-ztlz-hub, rg-ztlz-workload, rg-ztlz-shared and rg-ztlz-tfstate is a read.
# It writes no file into the repo and reads no file from it.
#
# WHAT IT CANNOT TOUCH: it has no create, update or delete command pointed at
# any resource group other than rg-ztlz-verify, and it refuses to start if
# rg-ztlz-verify already exists, so it can never delete a group it did not make.

set -uo pipefail

VERIFY_RG="rg-ztlz-verify"
VM_SIZE="Standard_B1ls"
ADMIN_USER="azureuser"

# "<vnet resource group>|<vnet>|<subnet>|<short name>"
# Both spokes are checked. Each route table has exactly one association, and a
# missing association on one spoke is invisible if only the other is tested.
SPOKES=(
  "rg-ztlz-workload|vnet-ztlz-workload|snet-workload|workload"
  "rg-ztlz-shared|vnet-ztlz-shared|snet-workload|shared"
)

READ_ONLY_RGS=(rg-ztlz-hub rg-ztlz-workload rg-ztlz-shared rg-ztlz-tfstate)

FAILURES=0
KEYDIR=""
RG_CREATED=0

cleanup() {
  rc=$?
  echo
  echo "=== cleanup ==="
  if [ -n "$KEYDIR" ] && [ -d "$KEYDIR" ]; then
    rm -rf "$KEYDIR"
    echo "removed temp dir $KEYDIR (throwaway ssh key and route json)"
  fi
  if [ "$RG_CREATED" -eq 1 ]; then
    echo "deleting $VERIFY_RG - this blocks for a minute or two on purpose"
    if az group delete -n "$VERIFY_RG" --yes; then
      echo "deleted $VERIFY_RG"
    else
      echo "!!!"
      echo "!!! FAILED TO DELETE $VERIFY_RG - COMPUTE MAY STILL BE BILLING"
      echo "!!! run this yourself now:"
      echo "!!!   az group delete -n $VERIFY_RG --yes"
      echo "!!!"
    fi
  fi
  echo "--- post-run: compute left anywhere in the subscription ---"
  echo "VMs:"
  az vm list -o table
  echo "NICs:"
  az network nic list -o table
  for RG in "${READ_ONLY_RGS[@]}"; do
    echo "disks in $RG:"
    az disk list -g "$RG" -o table
  done
  echo -n "$VERIFY_RG still exists: "
  az group exists -n "$VERIFY_RG"
  exit $rc
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "=== 0. preflight ==="
for BIN in az python3 ssh-keygen; do
  if ! command -v "$BIN" >/dev/null; then
    echo "ERROR: $BIN not found and this script needs it"
    exit 1
  fi
done
if ! az account show --query "{subscription:name,id:id,user:user.name}" -o table; then
  echo "ERROR: az is not logged in"
  exit 1
fi

echo
echo "--- baseline: what compute exists before this run ---"
echo "VMs:"
az vm list -o table
echo "NICs:"
az network nic list -o table
for RG in "${READ_ONLY_RGS[@]}"; do
  echo "disks in $RG:"
  az disk list -g "$RG" -o table
done

if [ "$(az group exists -n "$VERIFY_RG")" = "true" ]; then
  echo
  echo "ERROR: $VERIFY_RG already exists. A previous run leaked it, or it is"
  echo "not this script's to delete. Contents:"
  az resource list -g "$VERIFY_RG" -o table
  echo "Inspect it, then delete it yourself:  az group delete -n $VERIFY_RG --yes"
  exit 1
fi

echo
echo "=== 1. firewall state decides the expected next hop ==="
FW_COUNT=$(az network firewall list --query "length(@)" -o tsv)
echo "firewalls in subscription: $FW_COUNT"
if [ "$FW_COUNT" = "0" ]; then
  EXPECT_NH="None"
  EXPECT_IP=""
  echo "expecting 0.0.0.0/0 -> None  (resting state, nothing billing)"
else
  EXPECT_NH="VirtualAppliance"
  EXPECT_IP=$(az network firewall list --query "[0].ipConfigurations[0].privateIPAddress" -o tsv)
  if [ -z "$EXPECT_IP" ]; then
    EXPECT_IP=$(az network firewall list --query "[0].ipConfigurations[0].privateIpAddress" -o tsv)
  fi
  if [ -z "$EXPECT_IP" ]; then
    echo "ERROR: a firewall exists but its private IP could not be read."
    echo "Without it, 'route points at the live firewall' cannot be told apart"
    echo "from 'route points at a dead IP', so this script will not guess."
    az network firewall list -o json
    exit 1
  fi
  echo "expecting 0.0.0.0/0 -> VirtualAppliance at $EXPECT_IP"
fi

echo
echo "=== 2. resolve an Ubuntu image alias ==="
IMAGE=$(az vm image list --query "[?urnAlias=='Ubuntu2404'].urn | [0]" -o tsv)
if [ -z "$IMAGE" ]; then
  IMAGE=$(az vm image list --query "[?urnAlias=='Ubuntu2204'].urn | [0]" -o tsv)
fi
if [ -z "$IMAGE" ]; then
  echo "ERROR: no Ubuntu alias in this CLI's offline image list"
  az vm image list -o table
  exit 1
fi
echo "image: $IMAGE"

echo
echo "=== 3. throwaway ssh key ==="
KEYDIR=$(mktemp -d)
ssh-keygen -t rsa -b 2048 -N '' -f "$KEYDIR/id" -q
echo "generated in $KEYDIR - removed at exit, nothing written to \$HOME"
echo "nobody logs into these VMs; the key only satisfies az vm create"

echo
echo "=== 4. create the ephemeral resource group ==="
LOC=$(az network vnet show -g rg-ztlz-hub -n vnet-ztlz-hub --query location -o tsv)
if [ -z "$LOC" ]; then
  echo "ERROR: could not read the hub vnet's location"
  exit 1
fi
echo "location taken from vnet-ztlz-hub: $LOC"
RG_CREATED=1
if ! az group create -n "$VERIFY_RG" -l "$LOC" \
     --tags purpose=route-verification ephemeral=true -o table; then
  echo "ERROR: could not create $VERIFY_RG"
  exit 1
fi

for S in "${SPOKES[@]}"; do
  IFS='|' read -r SRG SVNET SSUB SNAME <<<"$S"
  VM="vm-ztlz-verify-$SNAME"

  echo
  echo "=================================================================="
  echo "=== spoke: $SNAME   ($SVNET / $SSUB)"
  echo "=================================================================="

  SUBNET_ID=$(az network vnet subnet show -g "$SRG" --vnet-name "$SVNET" -n "$SSUB" --query id -o tsv)
  if [ -z "$SUBNET_ID" ]; then
    echo "ERROR: subnet $SSUB not found in $SVNET"
    FAILURES=$((FAILURES + 1))
    continue
  fi
  echo "subnet: $SUBNET_ID"

  echo "--- creating $VM: $VM_SIZE, no public IP, no NIC NSG, no zone ---"
  echo "    (no zone is deliberate: Standard_B1ls is restricted in zone 1"
  echo "     for this subscription - NotAvailableForSubscription)"
  T0=$SECONDS
  if ! az vm create \
      -g "$VERIFY_RG" \
      -n "$VM" \
      --image "$IMAGE" \
      --size "$VM_SIZE" \
      --subnet "$SUBNET_ID" \
      --public-ip-address "" \
      --nsg "" \
      --admin-username "$ADMIN_USER" \
      --authentication-type ssh \
      --ssh-key-values "$KEYDIR/id.pub" \
      --os-disk-delete-option Delete \
      --nic-delete-option Delete \
      -o table; then
    echo "ERROR: vm create failed for spoke $SNAME"
    FAILURES=$((FAILURES + 1))
    continue
  fi
  echo "vm create took $((SECONDS - T0))s"

  POWER=$(az vm get-instance-view -g "$VERIFY_RG" -n "$VM" \
          --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus | [0]" -o tsv)
  echo "power state: $POWER"
  if [ "$POWER" != "VM running" ]; then
    echo "ERROR: $VM is not running. Effective routes are returned only for a"
    echo "running VM, so any reading taken now would be an empty list that"
    echo "looks like 'no routes' rather than 'could not read'."
    FAILURES=$((FAILURES + 1))
    continue
  fi

  NIC_ID=$(az vm show -g "$VERIFY_RG" -n "$VM" \
           --query "networkProfile.networkInterfaces[0].id" -o tsv)
  if [ -z "$NIC_ID" ]; then
    echo "ERROR: could not read the NIC id for $VM"
    FAILURES=$((FAILURES + 1))
    continue
  fi
  echo "nic: $NIC_ID"

  echo "--- reading effective routes (can take up to a minute) ---"
  T0=$SECONDS
  if ! az network nic show-effective-route-table --ids "$NIC_ID" -o json \
       > "$KEYDIR/routes-$SNAME.json"; then
    echo "ERROR: effective route read failed for $SNAME"
    FAILURES=$((FAILURES + 1))
    continue
  fi
  echo "read took $((SECONDS - T0))s"

  if ! python3 - "$KEYDIR/routes-$SNAME.json" "$EXPECT_NH" "$EXPECT_IP" "$SNAME" <<'PY'
import json, sys

path, exp_nh, exp_ip, name = sys.argv[1:5]
with open(path) as fh:
    doc = json.load(fh)
routes = doc.get("value", []) if isinstance(doc, dict) else doc

print("  effective routes returned:")
print("    %-8s %-8s %-20s %-18s %s" % ("SOURCE", "STATE", "PREFIX", "NEXTHOP", "IP"))
for r in routes:
    print("    %-8s %-8s %-20s %-18s %s" % (
        r.get("source"), r.get("state"),
        ",".join(r.get("addressPrefix") or []),
        r.get("nextHopType"),
        ",".join(r.get("nextHopIpAddress") or [])))

active = [r for r in routes
          if "0.0.0.0/0" in (r.get("addressPrefix") or [])
          and r.get("state") == "Active"]

if not active:
    print("  FAIL [%s]: no ACTIVE 0.0.0.0/0 route." % name)
    print("  That is what a missing route-table association looks like.")
    sys.exit(1)
if len(active) > 1:
    print("  FAIL [%s]: %d active 0.0.0.0/0 routes; expected exactly one."
          % (name, len(active)))
    sys.exit(1)

r = active[0]
nh = r.get("nextHopType")
ips = r.get("nextHopIpAddress") or []
src = r.get("source")
ok = True

if src != "User":
    print("  FAIL [%s]: active default route source is %r, not 'User'." % (name, src))
    print("  The system default route is winning - the UDR is not applied here.")
    ok = False
if nh != exp_nh:
    print("  FAIL [%s]: next hop is %r, expected %r." % (name, nh, exp_nh))
    ok = False

if exp_nh == "None":
    if ips:
        print("  FAIL [%s]: next hop None but an IP is set: %s" % (name, ips))
        ok = False
else:
    if ips != [exp_ip]:
        print("  FAIL [%s]: next hop IP is %s, expected ['%s']." % (name, ips, exp_ip))
        print("  A route naming an IP the live firewall does not have is a")
        print("  blackhole that looks healthy from the route table alone.")
        ok = False

if ok:
    if exp_nh == "None":
        print("  PASS [%s]: 0.0.0.0/0 -> None, user route active, traffic dropped."
              % name)
    else:
        print("  PASS [%s]: 0.0.0.0/0 -> VirtualAppliance at %s, matches the live firewall."
              % (name, exp_ip))
    sys.exit(0)
sys.exit(1)
PY
  then
    FAILURES=$((FAILURES + 1))
  fi
done

echo
echo "=================================================================="
if [ "$FAILURES" -eq 0 ]; then
  echo "=== RESULT: PASS - both spokes show 0.0.0.0/0 -> $EXPECT_NH $EXPECT_IP"
else
  echo "=== RESULT: FAIL - $FAILURES problem(s), see the FAIL lines above"
fi
echo "=================================================================="

exit "$FAILURES"
