# Decisions and failures

Written so the project can be explained rather than demonstrated. Each entry
says what was decided, why, what the alternative was, and how it is verified.
A project nobody can interrogate is a repository.

---

## Why a dedicated subscription

**Decided:** build in a subscription with nothing else in it.

**Why:** policy at subscription scope applies to everything in the
subscription, including resources nobody remembered. Phase 5 switches off
public data-plane access and Phase 7 starts refusing deployments. In a
subscription with real work in it, the real work breaks.

**Alternative rejected:** a resource-group-scoped assignment in a shared
subscription. It narrows the blast radius but also makes the demonstration
weaker - subscription-scope enforcement is what an employer recognises.

**Verified by:** `az group list` returning only this project's groups.

---

## Why the state backend was created by hand

**Decided:** a one-off shell script creates the storage account, container,
CanNotDelete lock and role assignment. Terraform does not manage it.

**Why:** Terraform cannot create the backend it is about to store its state in.
Something has to exist first. Making that step a script rather than a portal
click means it is reviewable. It is NOT idempotent: it generates a fresh
random suffix on every run, so running it twice creates a second storage
account rather than converging on the first.

**Alternative rejected:** local state committed to the repo, or a second
Terraform workspace managing the first one's backend. The first leaks state and
breaks CI; the second moves the chicken-and-egg problem rather than solving it.

**Verified by:** `terraform init` succeeding against the remote backend, which
it does from Cloud Shell.

---

## Why shared key access is disabled on the state account

**Decided:** `--allow-shared-key-access false` on the storage account, with
`use_azuread_auth = true` in the backend block and `storage_use_azuread = true`
on the provider.

**Why:** a storage account key is a bearer credential that grants full
data-plane access and does not expire. Turning keys off means every caller must
present an Entra identity, which is auditable and revocable. It also means the
estate practises what the policy layer will later enforce on every other
account - the state account is the proof that running without keys is possible.

**Consequence worth knowing:** the two settings are separate. Disabling keys
without `use_azuread_auth` leaves a backend that cannot authenticate at all.

**Verified by:** `terraform init` succeeding, which it cannot do with keys
disabled and Entra auth off.

---

## Why CI has no stored secret

**Decided:** OIDC federation from GitHub Actions to an Entra app registration.
Three repository *variables* (client ID, tenant ID, subscription ID) and no
secrets.

**Why:** a client secret in a repository is a credential with a rotation
schedule nobody keeps. Federation exchanges a short-lived GitHub-signed token
for an Azure token at run time, so there is nothing to leak and nothing to
rotate. The three IDs are identifiers, not credentials - which is why they are
variables and visible.

**Alternative rejected:** a service principal secret in GitHub Secrets. Works
immediately, and is the thing every reviewer asks about.

**Verified by:** the workflow logging the OIDC subject claim on every run, and
by the apply working with no secret configured.

---

## Why one federated credential per environment, not per branch

**Decided:** credentials bound to `environment:plan` and `environment:prod`.

**Why:** the environment is also where GitHub's protection rules live, so
binding to it means the human approval gate and the credential boundary are the
same boundary. Branch-based subjects multiply with every branch and drift out
of step with the limit of 20 credentials per application.

**Consequence worth knowing:** a job with no `environment:` key presents a
`ref:refs/heads/...` subject, which matches neither credential and fails at
login. Every job that needs Azure must name an environment.

---

## Why the repository is public

**Decided:** public, not private.

**Why:** GitHub Free does not allow environment protection rules on private
repositories, and the required-reviewer gate on `prod` is part of what the
project demonstrates. Public also makes Cloud Shell cloning trivial, with no
credential handling in an ephemeral shell.

**Consequence worth knowing:** nothing in the repository may be a secret. The
three Azure IDs are safe to publish; a client secret would not have been. The
no-stored-secret decision above is what makes public viable.

---

## Why Terraform does not run on the workstation

**Decided:** edit and commit in WSL; run `terraform init/plan/apply` in Azure
Cloud Shell; treat GitHub Actions as the real pipeline.

**Why:** WSL2 Ubuntu 24.04 on this host cannot run Terraform. Go-compiled
binaries resolve AAAA records and attempt IPv6, and WSL has only a link-local
address with no IPv6 route. The failures are misleading - `network is
unreachable`, `cannot assign requested address`, and sometimes `no such host`,
which reads like DNS. Disabling IPv6 by sysctl does not help: Go still selects
IPv6 destinations. `gh` is affected by the same cause and is intermittently
flaky; retrying it works.

**Consequence worth knowing:** Cloud Shell runs with no mounted storage, so
every session starts from a fresh clone with no `.terraform/`. Any script meant
to run there must `terraform init` first. `up.sh` and `down.sh` do.

---

## Why the cost guards are built before the firewall

**Decided:** `up.sh`, `down.sh`, the nightly teardown and the budget-as-code
all land before the hub-and-spoke network is applied.

**Why:** Azure Firewall is the first resource in this build that bills by the
hour whether or not traffic passes it. A kill switch written after the thing it
kills is a kill switch that was not there on the day it was needed.

**Verified by:** the measured starting position - zero firewalls, zero public
IPs, one resource group - so the guards are in place before anything meters.

---

## Why the budget alert is a smoke detector, not a cap

**Decided:** `budget-ztlz-monthly` at $50/month with alerts at 25/50/80/100%
actual plus forecasted at 100%.

**Why $50 and not $20:** the firewall alone is roughly $40/month at two
four-hour sessions a weekend. A budget set below normal working spend fires
every month during correct operation, and an alert you learn to ignore is worse
than no alert. The useful threshold is the first one: a 25% alert arriving on
the 3rd of the month means something did not get torn down.

**What it does not do:** Azure budgets are notification-only. No cap, no
throttle, no halt. `down.sh` and the nightly teardown are the only things that
actually control spend.

**Consequence worth knowing:** five notifications is exactly the azurerm
provider's documented cap on `notification` blocks. An actual-100 and a
forecasted-100 sharing one threshold used to collide, with the forecasted one
silently dropped; that was fixed for provider 3.23.0 and this estate resolves
4.81.0, so both survive.

---

## FAILURE: federated credential subject format

GitHub repositories created on or after 15 July 2026 present an immutable
subject containing owner and repo IDs, not names:

    repo:OWNER@OWNERID/REPO@REPOID:environment:NAME

A name-based subject is accepted at creation without complaint and fails at
login with AADSTS700213. Build the subject from IDs.

**What turned this from a trace ID into one readable line:** the workflow logs
the subject each run actually presents. Without that, the failure is an opaque
Entra error code; with it, the mismatch is visible on screen.

---

## FAILURE: Terraform authentication in CI

`azure/login` signs in the az CLI. Terraform does not use that session: with no
`ARM_*` variables set it falls back to CLI auth and refuses, because Terraform
accepts CLI auth only from a user, never from a service principal.

**Fix:** `ARM_USE_OIDC` with `ARM_CLIENT_ID` / `ARM_TENANT_ID` /
`ARM_SUBSCRIPTION_ID`, so Terraform requests its own OIDC token.
`ARM_USE_AZUREAD` is separate and also required - it makes the storage backend
use Entra rather than account keys, which is what allows shared key access to
stay disabled on the state account.

**Why this is worth telling:** two successful-looking steps in a row. The login
step goes green, and the failure surfaces in Terraform as something that reads
like a permissions problem.

---

## FAILURE: a teardown script that reports success having done nothing

Found by review before it ran, not in production.

The draft `down.sh` targeted `azurerm_firewall.main`. Once the network module
is wired in, the real address is `module.network.azurerm_firewall.main`. A
dotted `-target` address that matches nothing is not an error in Terraform - it
prints "No changes" and exits 0. HashiCorp declined to make it an error,
reasoning that `count` and `for_each` make valid addresses hard to determine
before graph construction.

So the script would have printed "Firewall DOWN - meter stopped" having
destroyed nothing, and the meter would have run all night.

**Fix, and the general principle:** both scripts now verify against Azure
rather than against Terraform's exit code. `up.sh` requires a firewall
reporting `Succeeded` and exits 1 otherwise; `down.sh` requires
`az network firewall list` to return zero and exits 1 otherwise. The check is
written from the failure's perspective - it can detect the broken state, rather
than merely agreeing with the tool that claimed to act.

---

## FAILURE: a safety net that could never fire

Also found by review.

The draft nightly teardown workflow declared `environment: prod`, and `prod`
carries the required-reviewer rule. A job referencing an environment with
required reviewers enters a Waiting state and does not start until a human
approves; the run is auto-cancelled after 30 days. At 00:23 nobody approves it,
so the net never catches anything - and it would have looked configured.

Dropping `environment:` does not work either: the subject would then be
`ref:refs/heads/main`, matching neither federated credential.

**Fix:** a third environment with no reviewer and its own federated credential,
so the unattended job has an identity and no human gate. Recorded here because
"an approval gate on an unattended job" is a mistake worth being able to
describe.

---

## Policy layers

See `docs/policy-layers.md`. The decision in one line: Modify is evaluated
before Deny, so a Modify that repairs a request and a Deny that gates it are
complements rather than duplicates - and DeployIfNotExists runs only after a
resource exists, so it can converge an estate but can never prevent anything.
