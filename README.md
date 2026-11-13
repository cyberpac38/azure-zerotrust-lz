# Azure zero-trust landing zone

A private-endpoint-only Azure landing zone where security posture is defined
as Azure Policy deployed by Terraform and kept true by two remediation paths —
Event Grid for seconds, Azure Policy for guaranteed eventual convergence.

Resource prefix: `ztlz`. Naming: `<resource-type>-ztlz-<role>`. Single region.

## Status

29 of 76 steps. Complete: the Terraform state backend, keyless CI, the cost
guards, the repository controls that make everything after this enforced
rather than merely documented, the hub-and-spoke network, and the private DNS
zones. Private endpoints are next.

Two steps of the private DNS phase are open rather than done — pointing the
spokes at the firewall's DNS proxy, and the NXDOMAIN alert. Both are recorded
under **Open questions** in the decisions log, with the reason each is held.

The scope was trimmed on 2026-11-12: the AKS phase and the in-cluster policy
phase that depended on it were removed, taking the plan from 85 steps to 76.
The container registry went with them.

Nothing is running right now, by design — see **Cost**.

## How it is deployed

| Where | What runs there |
|---|---|
| **GitHub Actions** | the only thing that applies. Plan on every pull request, apply on merge to `main` behind a required human approval that administrators cannot bypass |
| **Azure Cloud Shell** | `terraform init / validate / plan` against a fresh clone. The shell is ephemeral, so each session re-clones and installs a pinned Terraform |
| **WSL** | editing, `git`, `az`, `gh`. Terraform cannot run here at all — see decisions |

## Cost

Azure Firewall is the only hourly meter in this estate, and it is absent
between work sessions rather than left running. `up.sh` brings it online,
`down.sh` takes it down, and a nightly workflow tears down anything still
running whether or not anyone remembered. A $50 monthly budget alerts from
25% upward, and the first alert at $12.50 is roughly ten firewall-hours.

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
