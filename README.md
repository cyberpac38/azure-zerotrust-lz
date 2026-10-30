# Azure zero-trust landing zone

Private-endpoint-only Azure landing zone. Security posture is defined as
Azure Policy deployed by Terraform, enforced in-cluster by Gatekeeper, and
kept true by two remediation paths — Event Grid for seconds, Azure Policy
for guaranteed eventual convergence.

Resource prefix: `ztlz`. Naming: `<resource-type>-ztlz-<role>`.

## Decision log
- [ ] Why user-assigned policy identity rather than system-assigned
- [ ] Why enforcement mode rather than the Audit effect for staged rollout
- [ ] Why Cilium over Azure NPM and Calico
- [ ] How the Terraform backend survives private-endpoint-only
- [ ] Why the firewall is ephemeral, and what that cost discipline saved
- [ ] What this architecture does NOT defend against

## Measurements
- [ ] Event Grid remediation path: __ seconds
- [ ] Azure Policy remediation path: __ minutes
- [ ] Full rebuild from empty: __ minutes
- [ ] Spend per build session: $__
