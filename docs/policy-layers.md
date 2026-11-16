# Policy layers

Decided before any JSON was written. Each layer maps to a phase.

Why this file exists: a policy repository without this decision becomes a pile
of definitions nobody can reason about. Every definition added later must name
the layer it belongs to and the reason it belongs there.

## The ordering fact that makes the layers work

Azure Policy evaluates effects in a fixed order on a create or update request:
`disabled` first, then `append` and `modify`, then `deny`, then `audit`, then
`manual`, then `auditIfNotExists`, with `denyAction` last. `deployIfNotExists`
runs only after the resource provider returns a success code.

Two consequences this design depends on:

1. **Modify runs before Deny.** A Modify that stamps missing tags onto a
   request fixes that request before a Deny requiring those tags ever sees it.
   Modify and Deny on the same property are not a contradiction — they are a
   repair followed by a gate.
2. **DeployIfNotExists runs after the resource exists.** It cannot prevent
   anything. It is the convergence layer, not the enforcement layer, so
   anything that must never exist has to be Deny.

## Deny - cannot be derived, so refuse at the door

Refuse the request. Use when the correct value encodes a decision only a human
can make, or when the property is immutable after creation so no later effect
could repair it.

- **Region outside `eastus`.** The estate is single-region by decision. A
  resource in the wrong region cannot be moved by any policy effect; it would
  have to be destroyed and rebuilt. Deny is the only effect with any power.
- **Public IP addresses anywhere but the hub firewall subnet.** A public IP on
  a spoke workload silently bypasses the 0.0.0.0/0 route through the firewall,
  which defeats the forced-tunnel design. Removing one afterwards breaks
  whatever attached it, so this is a gate rather than a repair.
- **Public network access on PaaS data planes** - storage, Key Vault, and
  anything else exposing `publicNetworkAccess`. Switching it off automatically
  on a live resource cuts off every caller currently using it. Leaving it on is
  a deliberate exception someone should have to argue for.
- **Storage accounts with shared key access enabled.** The state account
  already runs with `allowSharedKeyAccess` false, so this estate has proved it
  does not need keys. An account that wants them is an exception needing
  sign-off.

### The conflict this layer created with the private endpoints phase, resolved

The build runbook's draft deployed Key Vault with public access on, seeded a
secret, then flipped it off. A Deny on `publicNetworkAccess` at subscription
scope would have made that impossible: the deploy is refused before the
seeding can happen.

**That conflict no longer exists.** The private endpoints phase took the first
of the three options this file used to list - the secret is written from
inside the spoke, over the private endpoint, so the vault is never public and
no seeding window is needed. It is created with
`public_network_access_enabled = false` and `default_action = "Deny"` from its
first apply, and `seed-and-verify-vault.sh` writes the secret from a throwaway
VM in the shared spoke.

The consequence for this layer: **the Deny definition can be written at
subscription scope with no carve-out and no exemption.** The two other options
once listed here - scoping the Deny to named resource groups, and a time-boxed
exemption - are not needed and are not being held in reserve.

One thing this does constrain. Any future service in this estate that needs a
secret seeded must be reachable from inside the network before the secret is
written, because there is no longer a public window to fall back on. That is
the intended shape, and `seed-and-verify-vault.sh` is the pattern for it.

## DeployIfNotExists - missing and safely creatable

Create something absent. Only safe where adding the thing changes no
application behaviour, and it always runs after the resource already exists.

- **Diagnostic settings to the Log Analytics workspace**, per resource type.
  The canonical case: a diagnostic setting cannot break the resource it is
  attached to.
- **Private DNS zone group on a private endpoint.** An endpoint without one has
  no A record, so the name does not resolve inside the VNet and the service
  looks down to the application. Creating the zone group is purely additive.
  This is the automated counterpart to the private DNS phase's warning about
  incomplete zones.
- **Azure Firewall diagnostic categories to Log Analytics.** Step 4.5's
  NXDOMAIN alert queries `AZFWDnsQuery`. Without this policy that table is
  empty and the alert silently never fires - a monitoring step in a later phase
  depends on a policy from this layer.
- **Defender for Cloud plans on the subscription.**
- **Subscription activity log export.**

## Modify - present but wrong, safely correctable

Change a value in place. Only safe where the change is idempotent and cannot
break a running caller.

- **The three required tags** - `owner`, `env`, `project`, matching the
  defaults in `infra/variables.tf`. Tag writes never affect behaviour. Paired
  with a Deny that requires them, which Modify repairs first by the ordering
  above.
- **Inherit missing tags from the parent resource group**, so a resource
  created outside the pipeline still lands tagged.
- **`supportsHttpsTrafficOnly` on storage accounts.**

Deliberately NOT in this layer: **`minimumTlsVersion`**. Raising it is a
one-line Modify and breaks any client still on TLS 1.1 the moment it applies.
In this lab that is nobody, but the habit is what matters, so it belongs in
Deny with a stated migration path rather than in a silent rewrite.

## The fourth layer, named so it is not forgotten: Audit

Things worth reporting and deliberately not enforced. The governance dashboard
reports three numbers rather than one, and this layer is where the third comes
from: not "how compliant are we" but "what have we chosen to tolerate, and for
how long". A governance story with no tolerated set is one nobody believes.

Candidates: cost-relevant SKU choices, resources without a delete lock,
exemptions approaching expiry.

## Rule used to decide

A value that can be defaulted sensibly is Modify.
A value encoding a decision only a human can make is Deny.
A thing whose absence is the whole problem is DeployIfNotExists.
A thing you want visible but not blocked is Audit.

## Claims in this file that are judgement, not measurement

The layer assignments above are design decisions and are argued, not measured.
These mechanism claims have NOT been verified on this subscription and must be
before the policy repository phase builds on them:

- which requirements above have usable built-in definitions rather than needing
  custom JSON
- whether `publicNetworkAccess` is exposed as a policy alias for every service
  listed

The second and third are settled by:

    az policy definition list \
      --query "[?policyType=='BuiltIn' && contains(displayName,'public network access')].{name:name,display:displayName}" \
      -o table

    az provider show --namespace Microsoft.Storage \
      --expand resourceTypes/aliases \
      --query "resourceTypes[?resourceType=='storageAccounts'].aliases[?contains(name,'publicNetworkAccess')].name" \
      -o tsv
