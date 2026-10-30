# Decisions and failures

## Federated credential subject format
GitHub repos created on or after 15 July 2026 present an immutable subject
containing owner and repo IDs, not names:
  repo:OWNER@OWNERID/REPO@REPOID:environment:NAME
A name-based subject is accepted at creation and fails at login with
AADSTS700213. Build the subject from IDs. The workflow logs the subject
each run presents, which turned this from a trace ID into one line.

## Terraform authentication in CI
azure/login signs in the az CLI. Terraform does not use that session: with
no ARM_* variables set it falls back to CLI auth and refuses, because
Terraform only accepts CLI auth from a user, not a service principal.
Fix: ARM_USE_OIDC with ARM_CLIENT_ID / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID,
so Terraform requests its own OIDC token. ARM_USE_AZUREAD is separate and
also required — it makes the storage backend use Entra rather than account
keys, which is what allows --allow-shared-key-access false on the state
account.
