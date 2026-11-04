# Decisions

Why this estate is built the way it is. Each entry is the question someone
will ask, the answer, the alternative that was rejected, and what the choice
cost — because a decision with no cost attached is usually a decision nobody
actually made.

---

## What is this, and what is it meant to prove?

A private-endpoint-only Azure landing zone in which the security posture is
not a document but a set of enforced controls: Azure Policy deployed by
Terraform, enforced inside the cluster by Gatekeeper, and kept true by two
remediation paths — Event Grid for seconds, Azure Policy for guaranteed
eventual convergence.

The thing it is really demonstrating is the difference between a control that
is written down and a control that bites. Most of the decisions below are
instances of that one idea.

---

## Why a whole subscription for this?

Policy at subscription scope applies to everything in the subscription,
including resources nobody remembered. Phase 5 switches off public data-plane
access and Phase 7 starts refusing deployments. In a subscription with real
work in it, the real work breaks.

**Alternative rejected:** resource-group-scoped assignments inside a shared
subscription. That narrows the blast radius, but it also weakens the
demonstration — subscription-scope enforcement is the thing a reviewer
recognises, and scoping down to dodge the consequences is exactly the move
this project is arguing against.

**Cost:** a second subscription to manage, and no way to hide from my own
policies.

---

## Where are the secrets?

There are none, and that is a design property rather than a claim.

CI authenticates to Azure by OIDC federation: GitHub mints a short-lived
signed token at run time and Entra exchanges it for an Azure token. Nothing
is stored, so nothing can leak and nothing needs rotating. The three values
in the repository — client ID, tenant ID, subscription ID — are identifiers,
not credentials, which is why they are repository *variables* and visible.

Credentials are bound per environment (`plan`, `prod`, `teardown`) rather
than per branch, so the human approval gate and the credential boundary are
the same boundary. Branch-based subjects multiply with every branch and drift
out of step with the limit of 20 credentials per application.

**Alternative rejected:** a service principal secret in GitHub Secrets. It
works in five minutes and it is the first thing a reviewer asks about.

**Cost:** a federated credential's subject must match exactly, and a wrong
subject is accepted silently at creation and only fails at sign-in. The
workflow therefore prints the subject each run actually presented, which
turns that failure from an opaque Entra error code into one readable line.

**Consequence worth knowing:** a job with no `environment:` key presents a
`ref:refs/heads/...` subject, which matches no credential and fails to log
in. Every job that touches Azure must name an environment.

---

## The repository is public. Is that not a problem?

It is what makes the rest possible. GitHub Free does not allow environment
protection rules on private repositories, and the required-reviewer gate on
`prod` is one of the controls being demonstrated. Public also means Cloud
Shell can clone without handling a credential in an ephemeral shell.

It is only viable because of the decision above: with no stored secret, there
is nothing in the repository that must not be read. The two decisions hold
each other up.

**Cost:** everything here is permanently public, including Actions logs and
any artifact a workflow uploads. That is why the pipeline never uploads a
Terraform plan file, and why the budget's alerts target the Owner role rather
than an email address written into a file.

---

## Your state backend is reachable from the internet. In a zero-trust estate?

Deliberately, and it is the sharpest question in the project.

`rg-ztlz-tfstate` is explicitly excluded from policy. If the state backend sat
behind a private endpoint, GitHub-hosted runners could not reach it and the
pipeline would need self-hosted runners inside the VNet — real infrastructure,
running continuously, in the one project whose point is that nothing runs
between sessions.

What is *not* given up: shared key access is disabled on that account, so
reaching it still requires an Entra identity rather than a bearer key that
never expires. Blob versioning is on, so a corrupted state file is an
inconvenience rather than an incident, and a CanNotDelete lock sits on the
resource group.

**Alternative rejected:** private endpoint plus self-hosted runners. Correct
for production, disproportionate here.

**Cost:** one documented exception, and the discipline to say so out loud
rather than let someone find it.

---

## Why is Terraform pinned to one exact version everywhere?

Because Terraform records the version that last wrote the state file, and an
older binary then refuses to touch it. The original constraint was `>= 1.9.0`,
which made three different binaries all legal writers — CI on 1.9.8, the
workstation on 1.17.0, and Cloud Shell on whatever Microsoft had shipped that
day. Whichever wrote first would have locked the others out.

That is not hypothetical: Cloud Shell reported 1.17.0 one morning and 1.16.0
the same afternoon. Microsoft upgrades that image without asking, so the shell
cannot be trusted to supply a version at all. `up.sh` and `down.sh` fetch a
pinned binary instead.

**Alternative rejected:** a floor constraint, which is what every tutorial
shows and what caused the problem.

**Cost:** an exact pin means a mismatched binary refuses to run at all. That
is the point — it fails loudly at the start instead of silently stamping
state that something else cannot open.

---

## How do you know the pipeline applied what you reviewed?

Because it applies a plan file rather than re-planning. The original workflow
ran a bare `terraform apply`, which plans again internally — so what was
applied was never the thing anyone looked at, and anything that changed in
between went in unseen.

The plan is written and applied inside the same job. It is deliberately not
uploaded as an artifact and handed to a later job, because this repository is
public and so are its artifacts, and a plan file carries resolved resource
attributes.

**Alternative rejected:** uploading the plan from the pull-request job and
applying it on merge. Stronger in a private repository; a disclosure in this
one.

**Cost:** the plan shown on the pull request is advisory. The guarantee is
narrower — that nothing drifted between planning and applying — rather than
that the reviewed diff is byte-for-byte what landed.

---

## Why does the firewall only exist while you are working?

Azure Firewall bills by the hour whether or not traffic passes it. Roughly
$1.25/hour is a third-party figure for Central US in July 2026 — directional
only, not quoted from Microsoft — but the order of magnitude is what drives
the design: left running, it is most of a thousand dollars a month for an
estate nobody is using.

So it is absent by default. `up.sh` brings it up for a session, `down.sh`
takes it down, and a nightly workflow tears down anything still running
whether or not either was remembered. Cost control stops being a habit and
becomes a property of the system.

Both scripts verify against Azure rather than against Terraform's exit code,
because a targeted destroy whose address matches nothing prints "No changes"
and exits zero — a script that reports a stopped meter while the meter runs.

**Alternative rejected:** leaving it up and accepting the bill, or using a
cheaper appliance. The firewall is the component the architecture is about;
removing it to save money would remove the project.

**Cost:** every work session starts with a ten-minute deploy, and a merge
during a session will tear the firewall down. That collision has an entry of
its own below.

---

## Why does a route table exist when there is no firewall to point it at?

Because the alternative is a landing zone whose resting state is open
internet egress.

The first design had the route tables and their subnet associations share the
firewall's `count`, so the whole routing layer appeared and disappeared with
it. Between sessions the spokes would then have had no `0.0.0.0/0` route of
their own, Azure's default system route would have taken over, and the steady
state of a zero-trust estate — the state it is in for all but a few hours a
week — would have been every workload subnet reaching the internet directly.

What is gated is only the two resources that bill by the hour,
`azurerm_firewall` and `azurerm_public_ip`. The route table and its subnet
associations are always present. Only the next hop is conditional:

```hcl
next_hop_type          = var.firewall_enabled ? "VirtualAppliance" : "None"
next_hop_in_ip_address = var.firewall_enabled ? azurerm_firewall.main[0].ip_configuration[0].private_ip_address : null
```

`None` is not the same as no route. Azure drops traffic matching a `None`
route rather than falling through to the system default. So the resting state
is "the spokes cannot reach the internet", and bringing the firewall up
*relaxes* that to "the spokes reach the internet through an inspected path".
The direction of failure is the entire point: a forgotten flag costs egress,
not containment.

This is measured in the data plane rather than argued. Step 3.8 creates one
VM per spoke and reads its effective routes. With the firewall down, both
spokes report `User / Active / 0.0.0.0/0 / None`, and the system default
`0.0.0.0/0 -> Internet` is listed as `Invalid` — the user route is overriding
it, not merely sitting beside it. With the firewall up, both report
`User / Active / 0.0.0.0/0 / VirtualAppliance` at the firewall's live private
IP.

**Alternative rejected:** gating the route tables alongside the firewall,
which reads as the tidier version of the same idea — no firewall, nothing
pointing at a firewall. It also cannot be written: route tables use
`for_each = var.spokes`, and a resource cannot take both `for_each` and
`count`. The design error and the syntax error had the same root.

**Cost:** a `None` route drops silently, and the component that would log a
blocked egress is the firewall, which in that state is precisely what is
absent. A session where the flag was never flipped looks like a broken
network rather than a closed one. The compensating control is that `up.sh`
refuses to report success unless every `rt-ztlz-*` `default-egress` route
names the live firewall's private IP, and `down.sh` refuses unless every one
of them is back to `None`.

---

## What happens if something merges while the firewall is up?

The firewall is destroyed, and that is the pipeline behaving correctly.

A push to `main` touching `infra/**` or `policy/**` runs the apply job. That
job plans with no `-var`, and `infra/terraform.tfvars` sets only `prefix` and
`location`, so `firewall_enabled` resolves to its declared default of
`false`. The plan it builds is therefore "no firewall, no public IP, both
spoke routes back to `None`" — whatever an `up.sh` session put into state
twenty minutes earlier. Terraform is converging on what the repository
declares, which is the property every other entry in this document is asking
for.

Neither session script can prevent it. `up.sh` and `down.sh` allowlist what
*they* apply from Cloud Shell; the pipeline is a separate apply path, with its
own federated credential and no allowlist. A guard inside the scripts cannot
reach it, and should not try to — a script that could veto the pipeline would
be a bypass of the gate below.

The control is the `prod` environment's required reviewer, the same gate that
protects every other apply and which no longer has `can_admins_bypass`. The
apply waits. Nothing is destroyed until a human approves it.

Which relocates the risk rather than removing it: **the failure mode is
approving reflexively.** A merge approval during a live session is not the
routine one, and nothing on the approval screen says so.

**Consequence worth knowing:** there is no plan to read at the moment the
approval is requested. Environment protection holds the whole job, so the
apply job's own `Plan` step has not run yet, and an in-progress run returns
nothing from its logs. The signal that does exist sits on the pull request:
its `plan` job runs on every pull request, with no paths filter, planning
from the same commit with the same default — so a session-colliding merge
shows the firewall and public IP as destroys on the pull request itself,
before the merge button is pressed. That is the plan to read, and it is
readable in advance rather than after approving.

**Consequence worth knowing:** a pull request touching only `docs/**` or a
root-level script does not trigger the apply job at all, confirmed on pull
request #7, where `apply` reported as skipped. Documentation work during a
session is safe; the collision requires a change under `infra/` or `policy/`.

**Cost:** either infrastructure changes wait until the session is over, or a
merge costs a ten-minute rebuild. There is no version of this in which the
pipeline is both authoritative and willing to leave an undeclared firewall
running.

---

## Why is the nightly teardown written in `az` rather than Terraform?

A safety net must not depend on the thing it protects you from. An `az`-based
teardown still stops the meter when the state file is locked mid-apply,
drifted, or unreachable — and it also catches a firewall created outside
Terraform entirely, which `terraform destroy` never would.

The cost is state drift, and that drift is self-healing: the next `up.sh`
refreshes, sees the firewall gone, and plans to recreate it.

Its deletes are scoped by resource-group name so they are structurally unable
to reach anything outside this project, while its final verification is
subscription-wide — detection should be broader than action.

It runs on its own GitHub environment with no required reviewer, because an
unattended job pointed at an environment that requires human approval waits
for a human who is asleep.

---

## Why is the budget $50, and why is it not a cap?

Azure budgets are notification-only. No throttle, no halt, no cutoff. It is a
smoke detector; `down.sh` and the nightly teardown are the only things that
actually control spend. Anyone who describes a budget as a spending limit has
not read what it does.

$50 rather than $20 because the firewall alone is roughly $40 a month at two
four-hour sessions a weekend. A budget set below normal working spend fires
every month during correct operation, and an alert you learn to ignore is
worse than no alert. The useful threshold is the first one: 25% is $12.50,
about ten firewall-hours, so a 25% alert on the 3rd of a month means
something did not get torn down.

Notifications target the **Owner role** rather than an email address, because
an address written into a public repository is an address published.

---

## Why import the budget instead of letting Terraform create it?

It had been live since 1 November, and the alerts should never be off — least
of all during the window in which the thing that creates them is being
changed. `terraform import` adopts the existing budget; creating a second one
with the same name fails outright.

`start_date` forces replacement when it changes, so the dates in the code are
the portal's exact values. A mismatch there would not have been a typo — it
would have destroyed and rebuilt the only live cost alarm.

**Consequence worth knowing:** importing before merging left a window in
which state contained the budget and `main` did not, during which any apply
on `main` would have planned to *destroy* it. The opposite order would have
had the apply try to create a resource that already exists and fail. Neither
order is free; the chosen one fails safe only as long as the window is short.

---

## Can you bypass your own gates?

No, and that was not true until it was fixed.

The `prod` environment requires a reviewer, but `can_admins_bypass` was true,
so the owner could skip the gate rather than pass it. An approval gate its
owner can walk around is a documented control, not an enforced one. It is now
off.

`main` was unprotected entirely — the pull-request flow existed by convention
while direct pushes were possible, and had happened repeatedly. A ruleset now
requires a pull request and a passing `plan` check, blocks force-pushes and
branch deletion, and has **no bypass actors**. It was verified by attempting a
direct push and being refused, because a rule that exists and does not bite is
worse than no rule — it produces false confidence.

Required approvals are set to **zero**, deliberately. GitHub does not let
anyone approve their own pull request, so on a solo repository any other value
makes the repository permanently unmergeable. The human checkpoint is the
`prod` deployment approval, which is real; a review requirement nobody can
satisfy would be theatre.

**Cost:** every change, including a one-line documentation fix, goes through a
pull request. The escape hatch is editing the ruleset in settings, which is
visible and auditable rather than silent.

---

## Why two secret scanners?

GitHub's secret scanning and push protection are enabled, and push protection
is the one that matters: it blocks a known-format credential at push time
instead of alerting after it is public. That is prevention rather than
detection, the same distinction the policy layers draw between Deny and
DeployIfNotExists.

But GitHub's scanning only matches *known provider token formats*. Generic
patterns — private keys, high-entropy strings — need GitHub Secret Protection
on an organization plan, which this repository does not have. A service
principal JSON blob matches no vendor's format, and that is exactly the thing
most likely to leak from a project like this.

So the pipeline runs gitleaks, pinned to one version and verified by checksum.

**And it proves it can fail before it is trusted to pass.** gitleaks silently
drops findings containing global allowlist stopwords, so "no leaks found" does
not by itself mean the scanner works. Every run scans a known-bad fixture
first and fails the job if that fixture is *not* detected. The fixture is
assembled at runtime from two halves, so no token-shaped literal is ever
committed — which push protection would block and this same scan would flag.

**Cost:** a download from github.com sits in the critical path of a required
check. If it fails, the pull request is blocked rather than silently
unscanned, which is the right direction to fail in.

---

## Why three policy layers?

See [policy-layers.md](policy-layers.md). In one line: Azure Policy evaluates
`modify` before `deny`, so a Modify that repairs a request and a Deny that
gates it are complements rather than duplicates — while `deployIfNotExists`
runs only after a resource already exists, so it can converge an estate but
can never prevent anything.

---

## What have you deliberately not done?

- **Narrowed the CI identity.** It holds Contributor and User Access
  Administrator at subscription scope, which is the broadest privilege in the
  project. Subscription-scoped policy assignments grant roles to their own
  remediation identities, which requires it. With a management group and a
  separate identity per scope it would be narrower; that is the honest answer,
  and narrowing happens when the project's resource groups exist.
- **Dependabot.** Dependabot-triggered runs get a read-only token and no
  Actions secrets, and whether they can obtain `id-token: write` for OIDC is
  undocumented. Enabling it without solving that produces permanently
  unmergeable pull requests every week. It needs the plan job split into an
  Azure-free validation job and an Azure-dependent one.
- **Pinned the GitHub Actions by commit SHA.** They are pinned by major tag,
  which is mutable. Dependabot is the mechanism that makes SHA pinning
  maintainable, so this waits on the item above.
- **Scanned git history in CI.** The pipeline scans the working tree. The full
  history was scanned once, separately, and was clean; ongoing history
  scanning needs a full-depth checkout on every run.
- **Solved the scheduled-workflow expiry.** GitHub disables scheduled
  workflows after 60 days with no repository activity, and this repository is
  public. Any commit resets that clock, and the budget's first alert is the
  backstop, but the residual risk is real: returning after a long gap,
  deploying, and forgetting, before making any commit.

---

## Failures worth recording

Six, in the order they were found. Each one looked like success at the time.

**Federated credential subject format.** Repositories created on or after 15
July 2026 present an immutable subject containing owner and repo IDs rather
than names. A name-based subject is accepted without complaint at creation and
fails at sign-in with `AADSTS700213`. Build it from IDs. The workflow now logs
the subject each run presents, which turned an opaque error code into one
readable line.

**Terraform authentication in CI.** `azure/login` signs in the Azure CLI;
Terraform does not use that session. With no `ARM_*` variables it falls back to
CLI auth and refuses, because Terraform accepts CLI auth only from a user,
never from a service principal. Two green steps in a row, then a failure that
reads like a permissions problem. `ARM_USE_OIDC` plus the three IDs fixes it;
`ARM_USE_AZUREAD` is separate and also required, and is what lets shared key
access stay disabled on the state account.

**A teardown that reported success having done nothing.** The draft `down.sh`
targeted `azurerm_firewall.main`, but once the module is wired in the real
address is `module.network.azurerm_firewall.main`. A dotted `-target` that
matches nothing is not an error in Terraform — it prints "No changes" and exits
zero. The script would have printed "meter stopped" and left it running all
night. Both scripts now verify against Azure rather than against an exit code.

**A safety net that could never fire.** The nightly teardown was written
against the `prod` environment, which carries a required reviewer. A job
referencing such an environment waits for a human and is cancelled after 30
days. It would have looked configured and never once run.

**A required check that could never report.** The branch ruleset requires a
check named `plan`, while the workflow only ran on pull requests touching
`infra/**`. A documentation-only pull request would never have triggered it,
leaving the check pending forever and the pull request unmergeable. Found
before it bit, by tracing the rule forward rather than waiting for it.

**A concurrency group that could cancel the net.** The nightly teardown
originally shared the deployment workflow's concurrency group, to serialise it
against applies. But with the default `queue: single`, a newer queued run
cancels and replaces the older pending one — so if an apply awaiting approval
held the group, successive nightly runs would have cancelled each other and
the net would have stopped firing silently. It now has its own group and
tolerates the race it no longer serialises.

The pattern in all six: the failure mode was *looking fine*. That is why the
verification in this project is written from the failure's perspective — the
question is never "did it work" but "what would this look like if it were
broken, and can this check see that".

---

## Open questions

Answered as the phases that settle them land. An empty answer here means it
has not been decided, not that it has been forgotten.

- Why a user-assigned policy identity rather than system-assigned
- Why enforcement mode rather than the Audit effect for staged rollout
- Why Cilium over Azure NPM and Calico
- Whether AKS private-cluster mode is immutable after creation, which decides
  whether Deny is the only effect with power over it
- Which policy requirements have usable built-in definitions rather than
  needing custom JSON
- What this architecture does **not** defend against
