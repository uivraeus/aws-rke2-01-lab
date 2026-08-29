# Sourced automatically by the *-vault Make targets (apply-vault/plan-vault/
# destroy-vault/bootstrap-vault), which also manage the SSM tunnel to Vault
# themselves. Only source this by hand if you want to run raw `terraform
# -chdir=terraform-vault` commands yourself - in that case you also need
# `make tunnel-vault` running in its own shell, `make create-operator-vault` (or
# bootstrap-vault) already run, and ../kubeconfig fetched (`make bootstrap-k8s` does
# that as part of the RKE2 install).

_vault_tf_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TF_VAR_vault_addr="http://localhost:8200"

# The exact filename depends on how the dynamic inventory named the Vault host at
# bootstrap time, hence the glob rather than a fixed name - resolved to the most
# recently written match, since destroy-all doesn't clean up local/ and an unquoted
# glob passed straight to `source` would otherwise silently source only the
# alphabetically-first match (not necessarily the current one) and ignore the rest.
# shellcheck source=/dev/null
source "$(ls -t "$_vault_tf_dir/../local"/terraform-operator-*.env | head -1)"

export TF_VAR_kubernetes_host="https://$(terraform -chdir="$_vault_tf_dir/../terraform" output -raw control_private_ip):6443"

export TF_VAR_kubernetes_ca_cert="$(
  kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
    --kubeconfig="$_vault_tf_dir/../kubeconfig" | base64 -d
)"

# Created automatically by scripts/bootstrap-vault.sh; if sourcing this by hand before
# that's run, create it manually first (see docs/vault.md):
#   kubectl --kubeconfig kubeconfig -n vault-auth create token vault-auth-delegator \
#     --duration=8760h > local/vault-k8s-reviewer.token
export TF_VAR_k8s_token_reviewer_jwt="$(cat "$_vault_tf_dir/../local/vault-k8s-reviewer.token")"

export TF_VAR_vault_test_role_arn="$(terraform -chdir="$_vault_tf_dir/../terraform" output -raw vault_test_role_arn)"

unset _vault_tf_dir
