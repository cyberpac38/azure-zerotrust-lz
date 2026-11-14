# Session cost log

Cost control is one of the five things this project exists to demonstrate, so
the saving is recorded as evidence rather than claimed. A scheduled teardown
with a measured saving is a FinOps artifact; a scheduled teardown with an
estimate attached is a script.

Every rate in this file was read from Microsoft's own price feed, and every
spend figure from Cost Management. Nothing here is an estimate. Where a number
cannot be observed it is labelled a bound or an open question.

## This subscription carries a second project

Measured 2026-11-14: the subscription holds **six** resource groups, not four.
`rg-ztlz-tfstate`, `rg-ztlz-hub`, `rg-ztlz-workload` and `rg-ztlz-shared` are
this project. `NetworkWatcherRG` is created by Azure with the first virtual
network and costs nothing. **`rg-RAG` in eastus2 is an unrelated project** and
holds an Azure OpenAI account.

This matters for every figure below. A subscription-wide total is not this
project's cost, and the $50 budget is scoped to the subscription, so the other
project's spend counts against the same alert thresholds. Every cost query in
this file therefore groups by resource group, and only `rg-ztlz-*` rows are
attributed here.

A seventh group, `rg-ztlz-verify`, appears in billing but never in a resource
group listing: `verify-routes.sh` creates and deletes it inside a single run,
so billing is the only place its existence is recorded after the fact.

## The rates

Read 2026-11-13 from the Azure Retail Prices API, which is Microsoft's own
unauthenticated price feed. The human pricing pages render their numbers in
JavaScript and serve blanks to anything that is not a browser, which is why
the feed is used instead.

| Meter | Rate | Unit | Region in the feed |
|---|---|---|---|
| Azure Firewall `Standard Deployment` | $1.25 | hour | eastus |
| Azure Firewall `Standard Data Processed` | $0.016 | GB | eastus |
| `Standard IPv4 Static Public IP` | $0.005 | hour | eastus |
| `Standard Private Endpoint` | $0.01 | hour | **Global** |
| `Standard Data Processed - Ingress` / `- Egress` | $0.01 | GB | Global |
| Azure DNS `Private Zone` | $0.50 | zone | Global |

The private endpoint meter is filed under region `Global`, not `eastus`. Every
query filtered to `eastus` returns nothing for it, which costs an afternoon if
you do not know.

Reproduce any of them:

```
https://prices.azure.com/api/retail/prices?$filter=serviceName eq 'Azure Firewall' and armRegionName eq 'eastus'
https://prices.azure.com/api/retail/prices?$filter=productName eq 'Virtual Network Private Link' and armRegionName eq 'Global'
https://prices.azure.com/api/retail/prices?$filter=serviceName eq 'Virtual Network' and armRegionName eq 'eastus'
```

### Two meters that exist and have never billed here

- **`Standard Capacity Unit`**, Azure Firewall Standard, $0.07 per hour, in
  effect since 2025-11-01. It appears in the price feed and has **not appeared
  in thirteen days of billing**, including a real firewall session. Whether it
  bills under sustained throughput is unmeasured. It postdates this project's
  original cost model, which is why it is recorded here rather than assumed
  away.
- **`Fixed Private Endpoint T1`**, $14.00 per hour, region Global, in effect
  since 2026-10-01. No Microsoft documentation describing it was found. It has
  not billed here, and `azurerm_private_endpoint` at provider v4.81.0 exposes
  no tier or SKU argument, so nothing in this configuration can request one.
  At $14 an hour it would pass the first budget alert inside an hour, so the
  first cost read after creating any endpoint checks for it.

## What has actually been spent

Cost Management, `ActualCost`, 2026-11-01 to 2026-11-14, grouped by resource
group and meter.

| Resource group | Spend | Largest lines |
|---|---|---|
| `rg-ztlz-hub` | **$2.1959** | `Private Zone` $1.1032, `Standard Deployment` $1.0837, `Standard IPv4 Static Public IP` $0.0090 |
| `rg-ztlz-shared` | **$0.1144** | `Standard Private Endpoint` $0.1144 |
| `rg-ztlz-verify` | **$0.0014** | `B1ls` $0.00069, `P4 LRS Disk` $0.00067 |
| `rg-ztlz-tfstate` | **$0.0008** | storage operations and data stored |
| **This project** | **$2.3125** | |
| `rg-RAG` — not this project | $0.0422 | Azure OpenAI tokens |

Subscription total for the same window: $2.3547.

That endpoint is rate-limited per subscription and answers `429` readily. One
query with a backoff, not several in a row. `az consumption usage list` is a
preview command and returns empty meter details on this subscription, so it is
not used here. The query that produced the table above groups by
`ResourceGroupName` and `Meter` together, which is what makes attribution
possible at all.

## Standing cost: what this estate costs with nothing running

| Permanent meter | Monthly |
|---|---|
| `Standard Private Endpoint`, one endpoint, 730 hours | $7.30 |
| `Private Zone`, six zones | $3.00 |
| **Total** | **$10.30** |

The private endpoint is permanent rather than session-only on purpose: checkov
`CKV2_AZURE_32` requires a Key Vault to have one, and the plan CI scans is the
resting state, so gating it would fail that check on every future pull request
or force a permanent exception in a repository named `azure-zerotrust-lz`. At
$0.01 an hour against the firewall's $1.25 it is roughly a hundred and
twenty-fifth of the cost, so the firewall is the meter worth switching off and
the endpoint is not.

### What that leaves for firewall sessions

The $50 budget alerts at 25%, 50%, 80% and 100% of actual spend plus 100%
forecast. The first alert is $12.50.

- Standing cost: $10.30 a month.
- Headroom to the first alert: **$2.20**, which at the measured session cost
  below is **about two one-hour firewall sessions a month**.
- Headroom to the full budget: roughly thirty firewall-hours.
- The budget covers the whole subscription, so `rg-RAG` spends from the same
  headroom.

## Sessions

| Date | Firewall up (UTC) | Down (UTC) | Firewall hours | Measured spend | Notes |
|---|---|---|---|---|---|
| 2026-11-04 | 15:17 | ~16:09 | **0.867 (billed)** | **$1.0837** firewall, plus public IP — see the open question | Steps 3.8/3.9, route verification. `verify-routes.sh` added $0.0014. |
| 2026-11-05 | - | - | 0 | zones bill monthly, not hourly | Steps 4.1-4.3, private DNS. 8 zones and 24 links applied. |
| 2026-11-12/13 | - | - | 0 | no hourly meter touched | Scope trim: the Kubernetes phases cut, the two registry zones and their six links removed, leaving 6 zones and 18 links. |
| 2026-11-13/14 | - | - | 0 | **$0.1144 and counting** | Step 5.1, PR #14. The Key Vault and its private endpoint. First permanent hourly meter in the estate. |

### The 4 November session, now exact

`Standard Deployment` billed **$1.08368055555556** in `rg-ztlz-hub`. At $1.25
an hour that is **0.86694 hours, or 52.0 minutes** of firewall existence.

That replaces the bound this table carried for ten days. The original figure
was "somewhere between roughly 50 and 59 minutes", derived from `up.sh`
starting at 15:10:40 and terraform writing state at 16:10:04 — neither of
which is the firewall's own lifetime. Billing is a source that outlived the
Cloud Shell session which lost the exact number.

Derived rather than measured: 52.0 minutes of existence against destruction
beginning around 16:01:35 is consistent with a destroy of roughly 7.5 minutes.
That chains off the 15:17 create timestamp, so the destroy duration is still
owed as a direct measurement at the next teardown.

### The private endpoint's rate, confirmed

`Standard Private Endpoint` billed **$0.1144** against an endpoint created
2026-11-13T20:33Z. At $0.01 an hour that is **11.44 hours**, consistent with
roughly eighteen hours elapsed and the usual billing lag.

The quantity is fractional, so partial hours are billed as partial hours. A
pricing page copy claiming partial hours are charged as full hours is
contradicted by this measurement.

### `verify-routes.sh` costs a tenth of a cent

Two `Standard_B1ls` VMs and their disks, created and destroyed inside one run:
`B1ls` $0.0006933472 plus `P4 LRS Disk` $0.0006704965, **$0.0014 for the whole
run**, billed to `rg-ztlz-verify`. Proving the data plane costs less than a
rounding error.

## Firewall lifecycle timings - measured 2026-11-04

No published figure for this was found, so these are this estate's own numbers.
Every session estimate depends on them.

- Azure Firewall create: **6m26s** (exact, from the apply log). Standard tier,
  AZFW_VNet, eastus, attached to policy `afwp-ztlz`.
- Public IP create: 3s.
- Route table update, each spoke: 4s.
- Azure Firewall destroy: **between roughly 6 and 8.5 minutes - bounded, not
  measured.** Destruction began around 16:01:35 UTC and state was written at
  16:10:04 UTC. The exact `Destruction complete after ...` line was lost when
  the Cloud Shell session ended (see the open question below). Replace this
  with the exact figure next session.

Planning rule of thumb until the destroy figure is exact: budget about 10
minutes to bring the firewall up and about 10 minutes to take it down, on top
of whatever the session's actual work takes.

## Private endpoint creation timings - measured 2026-11-13

From the apply log of PR #14, the first time these were observed here:

- `azurerm_user_assigned_identity`: 3s.
- `azurerm_role_assignment` on the vault: 27s.
- `azurerm_private_endpoint`, including its DNS zone group: 57s.
- All four resources of the phase: about 89 seconds of wall time.

The Key Vault itself created inside that window. The run's own 5m37s span
includes the `prod` approval wait and is not an apply figure.

## Firewall private IP

Retrieval, from `infra/` in Cloud Shell:

```
terraform output -raw firewall_private_ip
```

Measured value, 2026-11-04T15:17Z: **10.10.0.4**

This is the first address in `AzureFirewallSubnet` (10.10.0.0/26). It is not
stable: the firewall is destroyed and recreated every session, and the address
is reassigned on each create. Read it, never assume it. Any document or route
that hardcodes it will silently point at nothing the next time the firewall
comes up.

## Open question - the public IP billed twice the firewall's hours

`Standard IPv4 Static Public IP` billed **$0.00900833333333333** in
`rg-ztlz-hub`. At $0.005 an hour that is **1.80 hours, or 108 minutes** —
**56 minutes more than the firewall existed.**

Measured, so that none of this is guesswork:

- The charge is in `rg-ztlz-hub`, not in the unrelated project's group, so it
  belongs to this estate.
- Zero public IPs exist subscription-wide, confirmed 4, 13 and 14 November.
- The firewall itself billed 52.0 minutes over the same window.

No cause is established. A public IP outliving its firewall across the create
and destroy windows would account for part of the gap, but that is a mechanism
rather than a measurement. Settle it with a daily breakdown of that one meter,
which shows whether the hours landed on 4 November alone or spilled onto the
5th - the latter would point at the nightly teardown sweeping an unattached
address hours later.

## Open question - Cloud Shell sessions ending before the script's final report

Both Cloud Shell runs on 2026-11-04 stopped producing output after terraform
finished but before the script printed its own closing report. The second run
ended with `The access token expiry UTC time '11/4/2026 4:30:35 PM' is earlier
than current UTC time '11/4/2026 5:18:43 PM'`.

Token expiry explains the second run. It is unproven for the first, and one
error message is not enough to assert a shared cause for both.

Azure state was correct on both occasions, confirmed independently from WSL
with `az` rather than from the script's own output: after the create, both
spoke route tables pointed at the live firewall; after the teardown, zero
firewalls and zero public IPs existed subscription-wide, both routes were back
to `None`, and the state blob lease was `available` / `unlocked` with no stuck
lock.

The practical consequence is that a timing number which exists only in the
terminal can be lost. Where a duration matters, take it from a source that
outlives the session - resource timestamps via `az`, or the state blob's
`lastModified` - rather than from scrollback. The 52.0-minute figure above is
that rule applied: billing recovered a number the terminal threw away.

## Running totals

- Sessions logged: 4
- Measured firewall hours: **0.867** (exact, from billing)
- Measured spend attributable to the firewall: **$1.0837**
- Measured spend attributable to this project, month to date: **$2.3125**
- Standing cost with nothing running: **$10.30 a month**
- Counterfactual if the firewall were left running: 730 hours x $1.25 =
  **$912.50 a month**, plus $3.65 for its public IP. Against $1.0837 actually
  spent on it, bringing the firewall up only for sessions has avoided about
  **99.9%** of what a left-running firewall would have cost in this period.

The last line is the number that goes in the write-up. Every figure in it is
this estate's own measurement.

## Still owed

- The exact firewall destroy duration, at the next teardown.
- The daily breakdown that settles the public IP question above.
- Whether `Standard Capacity Unit` ever bills, which needs a session with real
  traffic through the firewall.
