#!/usr/bin/env bash
#
# seed-and-verify-vault.sh - runbook steps 5.2 and 5.4, the private endpoints
# phase.
#
# Writes the phase's test secret into the Key Vault and reads it back, from a
# throwaway virtual machine inside the shared spoke, over the private
# endpoint. Step 5.3 already showed the same vault refusing a caller from
# outside the network with ForbiddenByConnection. This is the other half of
# that pair: the same data plane, reached from inside, working.
#
# WHY A VM AT ALL
#
# The vault has never been reachable from the internet. public_network_access
# is Disabled and the firewall default action is Deny, so there is no path to
# its data plane except the private endpoint, and the private endpoint has a
# private address inside a spoke. Nothing outside the VNet can write that
# secret - not this laptop, and deliberately not the pipeline.
#
# WHY THE VM NEEDS NO INTERNET
#
# The spoke's workload subnet has a 0.0.0.0/0 route whose next hop is None,
# so the firewall being absent means the VM has no internet egress at all.
# Everything this script needs still works:
#
#   - The instance metadata service at 169.254.169.254 is a link-local
#     address answered by the hypervisor. Microsoft documents that traffic to
#     it never leaves the host and that it is not subject to network security
#     groups, user-defined routes or Azure Firewall rules. That is where the
#     managed identity's token comes from.
#   - The vault's own name resolves to the private endpoint's address inside
#     the VNet, because the privatelink zone is linked to this spoke and the
#     endpoint's DNS zone group wrote the A record.
#   - So the token call and the vault call both stay inside Azure.
#
# It reports back the same way: the VM writes its results to /dev/console,
# the Azure host captures the serial port into boot diagnostics, and this
# script reads that through the control plane. Nothing is pushed out of the
# VM, which is the point - az vm run-command would need outbound 443 to Azure
# public addresses to return its results, and this VM has none.
#
# WHAT THIS SCRIPT CAN AND CANNOT TOUCH
#
# It creates exactly one resource group, rg-ztlz-seed, and deletes it in a
# trap. Every other Azure call it makes is a read. It never touches
# rg-ztlz-hub, rg-ztlz-workload, rg-ztlz-shared or rg-ztlz-tfstate, it
# changes no setting on the vault, the endpoint or any subnet, and it holds no
# credential of its own - the VM borrows the identity Terraform already
# declared and granted.
#
# It refuses to start if rg-ztlz-seed already exists, so a leak from an
# earlier run surfaces rather than doubling, and it will never delete a group
# it did not create.
#
# Shell: WSL. az works there; terraform does not, and none is needed here.

set -euo pipefail

RG="rg-ztlz-seed"
VM="vm-ztlz-seed"
LOCATION="eastus"
SECRET_NAME="test-secret"
SPOKE_RG="rg-ztlz-shared"
SPOKE_VNET="vnet-ztlz-shared"
SPOKE_SUBNET="snet-workload"
IDENTITY_RG="rg-ztlz-shared"
IDENTITY_NAME="id-ztlz-kv-seeder"
ZONE_RG="rg-ztlz-hub"
ZONE_NAME="privatelink.vaultcore.azure.net"

# Standard_B1ls, not a v2 size. Measured on this subscription: the Standard BS
# Family quota is 10, but Basv2, Bsv2 and Bpsv2 are all limit 0, and a v2
# request fails with a quota error that reads like a capacity problem.
VM_SIZE="Standard_B1ls"

fail() { echo; echo "FAILED: $*" >&2; exit 1; }

###############################################################################
# 0. Preconditions
###############################################################################
command -v az >/dev/null 2>&1 || fail "az is not on PATH."

SUB_NAME="$(az account show --query name -o tsv)"
SUB_ID="$(az account show --query id -o tsv)"
echo "==> subscription ${SUB_NAME} (${SUB_ID})"

if az group show -n "$RG" >/dev/null 2>&1; then
  fail "${RG} already exists. A previous run leaked it, or something else owns
that name. This script will not reuse or delete a group it did not create.
Inspect it, then remove it with: az group delete -n ${RG} --yes"
fi

###############################################################################
# 1. Discover everything, hardcode nothing
#
# Every value below is read from Azure. The vault's name carries a suffix
# derived from the subscription id, the endpoint's private address is assigned
# by Azure, and the identity's client id is generated - none of them can be
# written into a script and stay true.
###############################################################################
echo "==> reading the estate"

KV_NAME="$(az keyvault list -g "$SPOKE_RG" --query '[0].name' -o tsv)"
[ -n "$KV_NAME" ] || fail "no Key Vault found in ${SPOKE_RG}."
KV_HOST="${KV_NAME}.vault.azure.net"

ID_RESOURCE_ID="$(az identity show -g "$IDENTITY_RG" -n "$IDENTITY_NAME" --query id -o tsv)"
ID_CLIENT_ID="$(az identity show -g "$IDENTITY_RG" -n "$IDENTITY_NAME" --query clientId -o tsv)"
[ -n "$ID_CLIENT_ID" ] || fail "identity ${IDENTITY_NAME} not found in ${IDENTITY_RG}."

SUBNET_ID="$(az network vnet subnet show -g "$SPOKE_RG" --vnet-name "$SPOKE_VNET" -n "$SPOKE_SUBNET" --query id -o tsv)"
[ -n "$SUBNET_ID" ] || fail "subnet ${SPOKE_SUBNET} not found in ${SPOKE_VNET}."

# The address the vault's name must resolve to inside the VNet. Read from the
# zone rather than from the endpoint, because the zone record is what the VM's
# resolver will actually answer with - and comparing the two is step 5.4's
# real assertion.
ZONE_IP="$(az network private-dns record-set a show -g "$ZONE_RG" -z "$ZONE_NAME" -n "$KV_NAME" --query 'aRecords[0].ipv4Address' -o tsv 2>/dev/null || true)"
[ -n "$ZONE_IP" ] || fail "no A record for ${KV_NAME} in ${ZONE_NAME}. The
endpoint's DNS zone group has not written it, so nothing inside the VNet can
resolve the vault and this test cannot mean anything."

echo "    vault         : ${KV_NAME}"
echo "    identity      : ${IDENTITY_NAME} (${ID_CLIENT_ID})"
echo "    expected IP   : ${ZONE_IP}  (from the private zone's A record)"

# Proves the claim this script rests on, before it spends anything: the spoke
# has no internet egress right now.
FW_COUNT="$(az network firewall list --query 'length(@)' -o tsv)"
echo "    firewalls up  : ${FW_COUNT}  (0 means the spoke has no internet egress)"

SECRET_VALUE="seeded-from-${VM}-$(date -u +%Y%m%dT%H%M%SZ)"
echo "    secret value  : ${SECRET_VALUE}"

###############################################################################
# 2. Temporary files and the cleanup trap
#
# The trap is the only thing that sweeps this VM: the nightly teardown deletes
# firewalls and unattached public IPs and does not touch compute. A hard kill
# of this script would bypass it, which is why step 0 refuses to start when
# the group is already there - a leak surfaces on the next run.
###############################################################################
TMP="$(mktemp -d)"
cleanup() {
  echo
  echo "==> cleanup: deleting ${RG}"
  az group delete -n "$RG" --yes --no-wait >/dev/null 2>&1 || true
  rm -rf "$TMP"
  echo "    delete issued. Confirm with: az group list --query \"[?name=='${RG}']\" -o tsv"
}
trap cleanup EXIT

# There is no SSH key in this WSL home, and nobody logs into this VM - it has
# no public address and the subnet's NSG denies inbound from the internet. A
# throwaway key is generated rather than writing a permanent one into $HOME.
ssh-keygen -t rsa -b 2048 -N "" -f "${TMP}/key" -q

###############################################################################
# 3. The script the VM runs
#
# Written in Python rather than shell with curl: cloud-init is itself a Python
# program, so python3 is present on any image cloud-init can run on, whereas
# curl is an assumption. Only the standard library is used, because the VM
# cannot reach a package index.
#
# Output goes to /dev/console, which the Azure host captures into the boot
# diagnostics serial log. Every line is prefixed so this script can find them
# among the kernel's own output.
###############################################################################
cat > "${TMP}/seed.py" <<PYEOF
#!/usr/bin/python3
import json
import socket
import sys
import urllib.error
import urllib.request

VAULT_HOST = "${KV_HOST}"
CLIENT_ID = "${ID_CLIENT_ID}"
SECRET_NAME = "${SECRET_NAME}"
SECRET_VALUE = "${SECRET_VALUE}"
EXPECT_IP = "${ZONE_IP}"

try:
    CON = open("/dev/console", "w")
except Exception:
    CON = None

LINES = []


def say(msg):
    line = "ZTLZSEED " + msg
    LINES.append(line)
    for sink in (CON, sys.stdout):
        if sink is None:
            continue
        try:
            sink.write(line + "\n")
            sink.flush()
        except Exception:
            pass


def replay():
    # The serial log is captured by the host, and boot diagnostics may not be
    # recording yet at the moment cloud-init runs this. So the whole report is
    # written again several times over the next few minutes: the reader greps
    # for the END marker and takes whichever copy landed. One write that
    # arrives too early to be captured would otherwise look identical to a
    # script that never ran.
    import time
    for _ in range(6):
        time.sleep(45)
        for line in LINES:
            for sink in (CON, sys.stdout):
                if sink is None:
                    continue
                try:
                    sink.write(line + "\n")
                    sink.flush()
                except Exception:
                    pass


def get(url, headers):
    req = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status, r.read().decode()


def put(url, headers, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="PUT")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status, r.read().decode()


say("START")
ok = True

# 1. DNS. Inside this VNet the vault's public name must resolve to the private
#    endpoint's address, because the privatelink zone is authoritative here.
try:
    resolved = socket.gethostbyname(VAULT_HOST)
    say("DNS " + resolved)
    if resolved == EXPECT_IP:
        say("DNS-MATCH yes")
    else:
        say("DNS-MATCH no expected=" + EXPECT_IP)
        ok = False
except Exception as e:
    say("DNS-ERROR " + type(e).__name__ + " " + str(e))
    ok = False

# 2. A token for the vault's data plane, from the instance metadata service.
#    Link-local, answered by the hypervisor, needs no egress.
token = None
try:
    url = ("http://169.254.169.254/metadata/identity/oauth2/token"
           "?api-version=2018-02-01"
           "&resource=https%3A%2F%2Fvault.azure.net"
           "&client_id=" + CLIENT_ID)
    status, body = get(url, {"Metadata": "true"})
    token = json.loads(body)["access_token"]
    say("TOKEN " + str(status) + " len=" + str(len(token)))
except urllib.error.HTTPError as e:
    say("TOKEN-ERROR http " + str(e.code) + " " + e.read().decode()[:200])
    ok = False
except Exception as e:
    say("TOKEN-ERROR " + type(e).__name__ + " " + str(e))
    ok = False

secret_url = ("https://" + VAULT_HOST + "/secrets/" + SECRET_NAME
              + "?api-version=7.4")
auth = None
if token:
    auth = {"Authorization": "Bearer " + token,
            "Content-Type": "application/json"}

# 3. Write the secret. This is runbook step 5.2, and it happens here because
#    there is nowhere else it can happen.
if auth:
    try:
        status, body = put(secret_url, auth, {"value": SECRET_VALUE})
        say("PUT " + str(status))
    except urllib.error.HTTPError as e:
        say("PUT-ERROR http " + str(e.code) + " " + e.read().decode()[:300])
        ok = False
    except Exception as e:
        say("PUT-ERROR " + type(e).__name__ + " " + str(e))
        ok = False

# 4. Read it back and check the value is the one just written, not an older
#    version. This is step 5.4.
if auth:
    try:
        status, body = get(secret_url, auth)
        value = json.loads(body).get("value", "")
        say("GET " + str(status))
        if value == SECRET_VALUE:
            say("GET-MATCH yes")
        else:
            say("GET-MATCH no got=" + value[:120])
            ok = False
    except urllib.error.HTTPError as e:
        say("GET-ERROR http " + str(e.code) + " " + e.read().decode()[:300])
        ok = False
    except Exception as e:
        say("GET-ERROR " + type(e).__name__ + " " + str(e))
        ok = False

say("END " + ("PASS" if ok else "FAIL"))
replay()
PYEOF

###############################################################################
# 4. The VM
#
# No public IP and no NIC-level NSG: nobody connects to this machine. Boot
# diagnostics with managed storage is the reporting channel, and Microsoft
# does not bill for the managed account's blobs. No zone is requested -
# measured on this subscription, Standard_B1ls in eastus carries a
# NotAvailableForSubscription restriction on zone 1.
###############################################################################
echo
echo "==> creating ${RG} and one ${VM_SIZE}"
az group create -n "$RG" -l "$LOCATION" --tags project=ztlz purpose=seed-verify -o none

az vm create \
  -g "$RG" -n "$VM" \
  --image Ubuntu2404 \
  --size "$VM_SIZE" \
  --subnet "$SUBNET_ID" \
  --public-ip-address "" \
  --nsg "" \
  --admin-username ztlzseed \
  --ssh-key-values "${TMP}/key.pub" \
  --assign-identity "$ID_RESOURCE_ID" \
  --boot-diagnostics-storage "" \
  --custom-data "${TMP}/seed.py" \
  --tags project=ztlz purpose=seed-verify \
  -o none

# The reporting channel depends on this being on. Checked rather than assumed,
# because if it is off the VM's report has nowhere to go and the run would
# fail for a reason that looks like the script never ran.
BD_ENABLED="$(az vm show -g "$RG" -n "$VM" --query 'diagnosticsProfile.bootDiagnostics.enabled' -o tsv 2>/dev/null || true)"
echo "    boot diagnostics enabled: ${BD_ENABLED:-unknown}"
if [ "$BD_ENABLED" != "true" ]; then
  echo "    enabling it now - the first copy of the report may already be lost,"
  echo "    which is why the VM repeats it for several minutes."
  az vm boot-diagnostics enable -g "$RG" -n "$VM" -o none || true
fi

echo "    Waiting for cloud-init to run the script and for the serial log to"
echo "    reach boot diagnostics. Microsoft documents this can take up to 10"
echo "    minutes, so this polls rather than guessing."

###############################################################################
# 5. Read the result back through the control plane
###############################################################################
LOG=""
FOUND="no"
for i in $(seq 1 40); do
  LOG="$(az vm boot-diagnostics get-boot-log -g "$RG" -n "$VM" 2>/dev/null || true)"
  if printf '%s' "$LOG" | grep -q 'ZTLZSEED END'; then FOUND="yes"; break; fi
  printf '    waiting for the result, attempt %s of 40\r' "$i"
  sleep 15
done
echo

if [ "$FOUND" != "yes" ]; then
  echo "==> the VM's report never reached the serial log."
  echo
  echo "    This script's reporting channel is the unproven part of it: the VM"
  echo "    writes to /dev/console and the Azure host is expected to capture"
  echo "    the serial port into boot diagnostics. If that is not happening,"
  echo "    whether the secret was written is UNKNOWN - re-running is safe,"
  echo "    because a PUT to the same secret creates a new version rather than"
  echo "    failing."
  echo
  echo "    The fallback is a firewall session: bring the firewall up with"
  echo "    up.sh so the spoke has inspected egress, add a rule allowing"
  echo "    AzureCloud on 443, and use az vm run-command, which Microsoft"
  echo "    documents as needing exactly that outbound path to return results."
  echo
  echo "    Last 60 lines of whatever the boot log does contain:"
  printf '%s\n' "$LOG" | tail -60
  exit 1
fi

RESULT="$(printf '%s\n' "$LOG" | grep 'ZTLZSEED' || true)"
echo "==> the VM's report, read from boot diagnostics:"
printf '%s\n' "$RESULT" | sed 's/^/    /'

###############################################################################
# 6. Assertions
#
# Written from the failure's perspective. An empty or partial report fails
# loudly rather than reading as success, and each check names the state it is
# looking for rather than just "did it work".
###############################################################################
echo
echo "==> assertions"
STATUS=0
check() {
  local label="$1" pattern="$2"
  if printf '%s' "$RESULT" | grep -q -- "$pattern"; then
    echo "    PASS  ${label}"
  else
    echo "    FAIL  ${label}"
    STATUS=1
  fi
}

check "the vault's name resolved to the private endpoint (${ZONE_IP})" "ZTLZSEED DNS ${ZONE_IP}"
check "DNS matched the zone's A record"                                "ZTLZSEED DNS-MATCH yes"
check "a data-plane token came from the instance metadata service"     "ZTLZSEED TOKEN 200"
check "the secret was written through the private endpoint"            "ZTLZSEED PUT 200"
check "the secret read back"                                           "ZTLZSEED GET 200"
check "the value read is the value written"                            "ZTLZSEED GET-MATCH yes"
check "the VM's own verdict is PASS"                                   "ZTLZSEED END PASS"

echo
if [ "$STATUS" -eq 0 ]; then
  echo "RESULT: PASS"
  echo
  echo "  The same vault that refused this laptop with ForbiddenByConnection"
  echo "  answered a caller inside the spoke, over the private endpoint, on a"
  echo "  machine with no internet route at all. Runbook steps 5.2 and 5.4."
else
  echo "RESULT: FAIL - read the lines above; the VM's own report is the evidence."
fi

exit "$STATUS"
