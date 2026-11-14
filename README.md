# Azure zero-trust landing zone

A private-endpoint-only Azure landing zone where security posture is defined
as Azure Policy deployed by Terraform and kept true by two remediation paths —
Event Grid for seconds, Azure Policy for guaranteed eventual convergence.

Resource prefix: `ztlz`. Naming: `<resource-type>-ztlz-<role>`. Single region.

## Status

30 of 76 steps. Complete: the Terraform state backend, keyless CI, the cost
guards, the repository controls that make everything after this enforced
rather than merely documented, the hub-and-spoke network, and the private DNS
zones.

The private endpoints phase is in progress. A Key Vault that has never been
reachable from the internet, its private endpoint, and the DNS record that
makes its own name resolve to a private address are applied and verified in
Azure. The remaining steps seed a secret from inside the network and prove the
control from both sides.

Two steps of the private DNS phase are open rather than done — pointing the
spokes at the firewall's DNS proxy, and the NXDOMAIN alert. Both are recorded
under **Open questions** in the decisions log, with the reason each is held.

The scope was trimmed on 2026-11-12: the AKS phase and the in-cluster policy
phase that depended on it were removed, taking the plan from 85 steps to 76.
The container registry went with them.

Two meters run permanently and everything expensive is absent between work
sessions — see **Cost**.

## How it is deployed

| Where | What runs there |
|---|---|
| **GitHub Actions** | the only thing that applies. Plan on every pull request, apply on merge to `main` behind a required human approval that administrators cannot bypass |
| **Azure Cloud Shell** | `terraform init / validate / plan` against a fresh clone. The shell is ephemeral, so each session re-clones and installs a pinned Terraform |
| **WSL** | editing, `git`, `az`, `gh`. Terraform cannot run here at all — see decisions |

## Cost

Four meters bill in this estate. Two are permanent, two exist only during a
work session, and every rate below was read from Microsoft's own price feed
rather than estimated.

| Meter | Rate | When it runs |
|---|---|---|
| Azure Firewall, `Standard Deployment` | $1.25/hour | session only |
| Its public IP, `Standard IPv4 Static Public IP` | $0.005/hour | session only |
| `Standard Private Endpoint` | $0.01/hour | permanent |
| `Private Zone`, six of them | $0.50 each | permanent |

That is **$10.30 a month with nothing running** — the private endpoint and the
six private DNS zones. Azure Firewall costs roughly a hundred and twenty-five
times the endpoint's hourly rate, so it is the one that is absent between
sessions: `up.sh` brings it online, `down.sh` takes it down, and a nightly
workflow tears down anything still running whether or not anyone remembered.

A $50 monthly budget alerts from 25% upward. The first alert at $12.50 is the
standing $10.30 plus about two one-hour firewall sessions — measured, from a
session that billed 52.0 minutes at $1.08. The budget is scoped to the
subscription, which also carries an unrelated project, so that project's spend
counts against the same alert.

Measured spend per session: [docs/cost-sessions.md](docs/cost-sessions.md).

## Documents

- **[docs/decisions.md](docs/decisions.md)** — every significant decision,
  the alternative that was rejected, and what the choice cost. Start here.
- **[docs/policy-layers.md](docs/policy-layers.md)** — which controls Deny,
  which DeployIfNotExists, which Modify, and the rule used to decide.
- **[docs/cost-sessions.md](docs/cost-sessions.md)** — measured spend per
  build session.

## Measured results

Filled in at the drills phase, from drills rather than estimates. An empty row
here means the drill has not been run, not that the number is unknown.

| Measurement | Result |
|---|---|
| Event Grid remediation path | __ seconds |
| Azure Policy remediation path | __ minutes |
| Full rebuild from empty | __ minutes |
