# Vault track — worklog

Dated entries of what was actually run against a live cluster/Vault instance, pulled
out of [design.md](design.md) to keep that doc focused on the current design rather
than the history of getting there.

## 2026-08-22 — Helm chart packaging, same result as the hand-authored ConfigMap

Same cluster/Vault version as the hand-authored [`vault-agent-config.yaml`](../manifests/infra/vault-agent-config.yaml)
path: chart-rendered credentials (via [`charts/vault-agent-aws-creds`](../../charts/vault-agent-aws-creds))
pass `aws sts get-caller-identity`, S3 access is scoped correctly in both directions
(allowed on the vault-test bucket, denied on the IRSA one), and automatic rotation
works identically to the hand-authored version - `AccessKeyId` changes after the
lease TTL with the pod's restart count staying at `0`. Re-verified with `vaultAddress`
unset entirely (the default): same result, `VAULT_ADDR` supplied by the injector alone.

## 2026-09-05 — Kyverno + vault-aws-credential-helper, no Vault Agent Injector at all

A plain Pod, with zero Vault-related annotations, volumes, or env vars of its own,
carrying only `serviceAccountName: vault-test` against a ServiceAccount holding the
two opt-in annotations, comes up `Running` with everything correctly injected -
`aws sts get-caller-identity` succeeds, and S3 scoping is correct in both directions
(allowed on the vault-test bucket, denied on the IRSA one). No Vault Agent Injector
Helm release is installed on the cluster at all for this to work.
