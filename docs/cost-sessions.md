# Session cost log

Cost control is one of the five things this project exists to demonstrate, so
the saving is recorded as evidence rather than claimed. A scheduled teardown
with a measured saving is a FinOps artifact; a scheduled teardown with an
estimate attached is a script.

Fill one row per work session. Read actual spend from
Cost Management -> Cost analysis, scoped to the subscription, for the day in
question. Do not copy the hourly estimate into this table - the point of the
table is to replace the estimate with a measurement.

| Date | Firewall up (UTC) | Down (UTC) | Hours | Measured spend | Notes |
|---|---|---|---|---|---|
| 2026-11-04 | 15:10:40 | 16:10:04 | ~0.9 | not yet read | Steps 3.8/3.9 route verification. See timings below. |

The 2026-11-04 spend cell is deliberately unfilled. Cost analysis lags roughly
a day, so the number is not readable yet. Read it on or after 2026-11-06 and
replace "not yet read" - an estimate written in now would be exactly the thing
this table exists to avoid.

The hours figure for that row is bounded rather than exact. 15:10:40 is when
`up.sh` started, which is before the firewall existed; 16:10:04 is when
terraform wrote state after the teardown applied, which is at or after the
firewall was gone. Actual firewall existence is therefore somewhere between
roughly 50 and 59 minutes, and the elapsed figure overstates it slightly.

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
`lastModified` - rather than from scrollback.

## Running totals

- Sessions logged: 1
- Measured firewall hours: ~0.9 (bounded - see the note under the table)
- Measured spend attributable to the firewall: not yet read
- Counterfactual if left running: hours in month x measured hourly rate

The last line is the number that goes in the write-up and on the CV. It is
only honest once the hourly rate in it is your own measurement.
