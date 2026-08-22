#!/usr/bin/env bash
# Full Vault bootstrap sequence: install + init (+ first unseal) Vault, create the
# terraform-operator AppRole, apply the vault-auth-delegator manifest and mint its
# token, then configure Vault itself (Kubernetes auth method + AWS secrets engine) via
# terraform-vault/. Invoked via `make bootstrap-vault` - assumes bootstrap-k8s has
# already run (the Vault EC2 instance is provisioned by the main terraform/ root, and
# this needs ../kubeconfig to exist).
#
# Single bootstrap/destroy cycle only, same as the rest of this repo: destroy-all
# doesn't (and shouldn't) clean up local/, so local/vault-*.json's glob can match a
# stale file from a previous instance across cycles - always resolved to the most
# recently written match below, since that one is always written earlier in this same
# run, immediately before it's read.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."  # repo root, regardless of invocation cwd

# make bootstrap-vault passes this in (the .ansible-venv path); falls back to
# whatever's on PATH if this script is run standalone.
ANSIBLE_PLAYBOOK="${ANSIBLE_PLAYBOOK:-ansible-playbook}"

AWS_PROFILE=$(terraform -chdir=terraform output -raw aws_profile)
AWS_REGION=$(terraform -chdir=terraform output -raw aws_region)
RKE2_CLUSTER_NAME=$(terraform -chdir=terraform output -raw cluster_name)
export AWS_PROFILE AWS_REGION RKE2_CLUSTER_NAME

echo "==> Installing Vault, running operator init (+ first unseal)"
(cd ansible && "$ANSIBLE_PLAYBOOK" vault.yml --tags install,init)

echo "==> Creating the terraform-operator AppRole"
VAULT_ROOT_TOKEN=$(jq -r .root_token "$(ls -t local/vault-*.json | head -1)")
export VAULT_ROOT_TOKEN
(cd ansible && "$ANSIBLE_PLAYBOOK" vault.yml --tags tokens)

echo "==> Applying the vault-auth-delegator ServiceAccount and minting its token (needs the k8s tunnel)"
K8S_TUNNEL_CMD=$(terraform -chdir=terraform output -raw tunnel_command)
scripts/with-tunnel.sh "$K8S_TUNNEL_CMD" 6443 -- bash -c '
  set -euo pipefail
  kubectl --kubeconfig kubeconfig apply -f manifests/vault-k8s-auth.yaml
  kubectl --kubeconfig kubeconfig -n vault-auth create token vault-auth-delegator --duration=8760h > local/vault-k8s-reviewer.token
'

echo "==> Configuring Vault (Kubernetes auth method + AWS secrets engine) via terraform-vault"
make apply-vault
