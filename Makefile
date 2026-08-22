TF_DIR := terraform
TF_VAULT_DIR := terraform-vault
ANSIBLE_DIR := ansible

# All Ansible steps run through a dedicated, gitignored venv instead of whatever (if
# anything) is on PATH - `make ansible-venv` creates/syncs it, and every target below
# that invokes ansible-playbook/ansible-galaxy depends on it so it's always ready.
# $(CURDIR) (repo root, where this Makefile lives) makes these absolute paths so they
# still resolve correctly after a recipe's own `cd $(ANSIBLE_DIR)`.
ANSIBLE_VENV := .ansible-venv
ANSIBLE_PLAYBOOK := $(CURDIR)/$(ANSIBLE_VENV)/bin/ansible-playbook
ANSIBLE_GALAXY := $(CURDIR)/$(ANSIBLE_VENV)/bin/ansible-galaxy

# Env vars ansible-playbook invocations need, read from Terraform outputs so nothing
# needs to be copy-pasted by hand. One line deliberately, to avoid Make's line-
# continuation-in-variables ambiguity.
ANSIBLE_ENV = AWS_PROFILE=$$(terraform -chdir=../$(TF_DIR) output -raw aws_profile) AWS_REGION=$$(terraform -chdir=../$(TF_DIR) output -raw aws_region) RKE2_CLUSTER_NAME=$$(terraform -chdir=../$(TF_DIR) output -raw cluster_name)

.PHONY: ansible-venv \
	init-k8s init-vault init-all \
	fmt-k8s fmt-vault fmt-all \
	validate-k8s validate-vault validate-all \
	plan-k8s plan-vault plan-all \
	apply-k8s apply-vault apply-all \
	destroy-k8s destroy-vault destroy-all \
	ansible-deps ansible-k8s \
	bootstrap-k8s bootstrap-vault bootstrap-all \
	restart reboot sync-oidc rotate-sa-key \
	tunnel-k8s tunnel-vault \
	create-operator-vault unseal-vault \
	injector-vault

# Creates .ansible-venv if missing and makes sure ansible/boto3/botocore are installed
# in it. Safe/fast to depend on from every ansible-invoking target: python3 -m venv is
# a no-op on an existing venv, and plain `pip install ansible` (no --upgrade) is a
# local-only "already satisfied" check when it's already there - no network round trip.
ansible-venv:
	@if [ ! -d $(ANSIBLE_VENV) ]; then python3 -m venv $(ANSIBLE_VENV); fi
	@$(ANSIBLE_VENV)/bin/pip install --quiet --upgrade pip
	@$(ANSIBLE_VENV)/bin/pip install --quiet ansible boto3 botocore

# --- Terraform ---
#
# Two independent roots: terraform/ provisions the AWS/k8s infra (including the Vault
# EC2 instance itself), terraform-vault/ configures Vault's own internals (Kubernetes
# auth method, AWS secrets engine) via the hashicorp/vault provider. -vault targets
# need Vault reachable, which only happens over an SSM tunnel - they open one just for
# their own duration via scripts/with-tunnel.sh, so none of them need a second shell
# running `make tunnel-vault` first (that's only for the manual verification steps).

init-k8s:
	cd $(TF_DIR) && terraform init

init-vault:
	cd $(TF_VAULT_DIR) && terraform init

init-all: init-k8s init-vault

fmt-k8s:
	cd $(TF_DIR) && terraform fmt -recursive

fmt-vault:
	cd $(TF_VAULT_DIR) && terraform fmt -recursive

fmt-all: fmt-k8s fmt-vault

validate-k8s:
	cd $(TF_DIR) && terraform validate

validate-vault:
	cd $(TF_VAULT_DIR) && terraform validate

validate-all: validate-k8s validate-vault

plan-k8s:
	cd $(TF_DIR) && terraform plan

plan-vault: init-vault
	VAULT_TUNNEL_CMD=$$(cd $(TF_DIR) && terraform output -raw vault_tunnel_command) && \
	scripts/with-tunnel.sh "$$VAULT_TUNNEL_CMD" 8200 -- \
	bash -c 'source $(TF_VAULT_DIR)/env.sh && terraform -chdir=$(TF_VAULT_DIR) plan'

plan-all: plan-k8s plan-vault

apply-k8s:
	cd $(TF_DIR) && terraform apply

apply-vault: init-vault
	VAULT_TUNNEL_CMD=$$(cd $(TF_DIR) && terraform output -raw vault_tunnel_command) && \
	scripts/with-tunnel.sh "$$VAULT_TUNNEL_CMD" 8200 -- \
	bash -c 'source $(TF_VAULT_DIR)/env.sh && terraform -chdir=$(TF_VAULT_DIR) apply -auto-approve'

# NOTE: this is just apply-k8s + apply-vault back to back - it does NOT run the
# Ansible/kubectl steps a working setup actually needs in between (Vault install/init,
# the terraform-operator AppRole, the vault-auth-delegator manifest + token). It's here
# only for symmetry with the other Terraform-wrapper targets; use bootstrap-all for the
# real end-to-end sequence.
apply-all: apply-k8s apply-vault

destroy-k8s:
	cd $(TF_DIR) && terraform destroy

# terraform/vault.tf provisions the Vault EC2 instance as part of apply-k8s
# regardless of whether bootstrap-vault ever ran, so destroy-all must tolerate
# terraform-vault having nothing in state (the common case for anyone who only
# wanted the base cluster/IRSA) - checking state first avoids opening a tunnel and
# trying to authenticate to a Vault that may never have been installed.
destroy-vault: init-vault
	if [ -z "$$(terraform -chdir=$(TF_VAULT_DIR) state list)" ]; then \
		echo "terraform-vault has nothing in state - skipping (Vault was never bootstrapped)."; \
	else \
		VAULT_TUNNEL_CMD=$$(cd $(TF_DIR) && terraform output -raw vault_tunnel_command) && \
		scripts/with-tunnel.sh "$$VAULT_TUNNEL_CMD" 8200 -- \
		bash -c 'source $(TF_VAULT_DIR)/env.sh && terraform -chdir=$(TF_VAULT_DIR) destroy -auto-approve'; \
	fi

# Order matters: terraform-vault's resources live inside Vault, which runs on the EC2
# instance destroy-k8s terminates - destroying k8s first would leave destroy-vault
# unable to reach Vault at all (and its state permanently orphaned). destroy-all always
# does it in the safe order; use it instead of the two separately when tearing
# everything down.
destroy-all: destroy-vault destroy-k8s

# --- Ansible ---

ansible-deps: ansible-venv
	cd $(ANSIBLE_DIR) && $(ANSIBLE_GALAXY) collection install -r requirements.yml

ansible-k8s: ansible-venv
	cd $(ANSIBLE_DIR) && $(ANSIBLE_ENV) $(ANSIBLE_PLAYBOOK) site.yml

bootstrap-k8s: apply-k8s ansible-k8s

# Full Vault setup from nothing to a working Vault-issued-credentials capability - see
# scripts/bootstrap-vault.sh for the actual sequence. Needs the k8s side already
# bootstrapped (that's where the Vault EC2 instance and ../kubeconfig come from).
bootstrap-vault: ansible-venv
	ANSIBLE_PLAYBOOK=$(ANSIBLE_PLAYBOOK) scripts/bootstrap-vault.sh

bootstrap-all: bootstrap-k8s bootstrap-vault

# Installs (or upgrades - `helm upgrade --install` is idempotent) the Vault Agent
# Injector, pointed at the existing external Vault instance rather than deploying
# Vault itself via the chart. `injector.enabled`/`server.enabled` override the
# defaults precisely; `global.externalVaultAddr` is the current (non-deprecated) key
# for this - `injector.externalVaultAddr` still exists but is a deprecated alias.
# Needs the k8s side already bootstrapped (reachability relies on the existing
# vault_from_cluster security group rule in terraform/vault.tf, nothing new to wire).
injector-vault:
	helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
	helm repo update hashicorp
	helm upgrade --install vault-injector hashicorp/vault \
		--version 0.34.1 \
		--namespace vault-injector --create-namespace \
		--set injector.enabled=true \
		--set server.enabled=false \
		--set global.externalVaultAddr=http://$$(cd $(TF_DIR) && terraform output -raw vault_private_ip):8200 \
		--kubeconfig kubeconfig

# Restarts rke2-server/rke2-agent and waits for the node(s) to report Ready again.
#   make restart               # both nodes
#   make restart LIMIT=control # just the control node
#   make restart LIMIT=worker  # just the worker node
restart: ansible-venv
	cd $(ANSIBLE_DIR) && $(ANSIBLE_ENV) $(ANSIBLE_PLAYBOOK) restart.yml $(if $(LIMIT),--limit $(LIMIT))

# Reboots the EC2 instance(s) at the OS level (vs. `restart`, which only restarts the
# rke2-server/rke2-agent service). Doesn't wait for the node(s) to come back - both
# services are enabled via systemd and RKE2's embedded etcd persists on the root
# volume, so they're expected to rejoin on their own; check with `kubectl get nodes`.
#   make reboot               # both nodes
#   make reboot LIMIT=control # just the control node
#   make reboot LIMIT=worker  # just the worker node
reboot:
	cd $(TF_DIR) && \
	AWS_PROFILE=$$(terraform output -raw aws_profile) ; \
	AWS_REGION=$$(terraform output -raw aws_region) ; \
	case "$(LIMIT)" in \
		control) IDS=$$(terraform output -raw control_instance_id) ;; \
		worker)  IDS=$$(terraform output -raw worker_instance_id) ;; \
		"")      IDS="$$(terraform output -raw control_instance_id) $$(terraform output -raw worker_instance_id)" ;; \
		*)       echo "LIMIT must be 'control' or 'worker', got: $(LIMIT)" >&2; exit 1 ;; \
	esac ; \
	aws ec2 reboot-instances --profile "$$AWS_PROFILE" --region "$$AWS_REGION" --instance-ids $$IDS

# Re-syncs the OIDC discovery document/JWKS from the live control node into the OIDC
# bucket, without re-running the rest of the playbook. Use this if IRSA token
# validation starts failing after an RKE2 upgrade rotates the service-account signing
# key - the mirror is only synced automatically during `make bootstrap-k8s`/`make ansible-k8s`.
sync-oidc: ansible-venv
	cd $(ANSIBLE_DIR) && $(ANSIBLE_ENV) $(ANSIBLE_PLAYBOOK) site.yml --tags oidc_sync

# Rotates the RKE2 service-account signing key per the documented procedure
# (https://docs.rke2.io/security/certificates) and verifies the outcome: the old key
# stays valid for already-issued tokens, and a freshly-issued token gets signed with
# the new key. Not part of the IRSA solution itself - a way to confirm RKE2's rotation
# behavior matches its docs. If this cluster is wired up for IRSA, follow up with
# `make sync-oidc`.
rotate-sa-key: ansible-venv
	cd $(ANSIBLE_DIR) && $(ANSIBLE_ENV) $(ANSIBLE_PLAYBOOK) rotate_service_account_key.yml

# Opens an SSM port-forward tunnel so `kubectl --kubeconfig kubeconfig` works from your
# laptop. Run this in its own shell and leave it running - needed for the manual
# verification steps in the README (the -vault Terraform targets above manage their
# own short-lived tunnels and don't need this held open).
tunnel-k8s:
	cd $(TF_DIR) && eval $$(terraform output -raw tunnel_command)

# Opens an SSM port-forward tunnel so Vault's API is reachable at localhost:8200. Run
# this in its own shell and leave it running - only needed for manual verification
# (e.g. applying manifests/vault-test.yaml); the -vault Terraform targets above manage
# their own.
tunnel-vault:
	cd $(TF_DIR) && eval $$(terraform output -raw vault_tunnel_command)

# --- Vault day-2 operations (already covered by bootstrap-vault/destroy-all - these
# are standalone re-runs for when only one piece needs redoing) ---

# Re-creates the terraform-operator AppRole terraform-vault/ authenticates as. Needed
# standalone if its secret_id needs regenerating without redoing the rest of
# bootstrap-vault. Requires VAULT_ROOT_TOKEN (see local/vault-*.json's root_token).
create-operator-vault: ansible-venv
	cd $(ANSIBLE_DIR) && $(ANSIBLE_ENV) $(ANSIBLE_PLAYBOOK) vault.yml --tags tokens

# Re-unseals Vault after a restart/reboot (storage "file" persists, but Vault always
# comes back sealed). Requires VAULT_UNSEAL_KEY_1.. set from local/vault-*.json's
# unseal_keys_b64.
unseal-vault: ansible-venv
	cd $(ANSIBLE_DIR) && $(ANSIBLE_ENV) $(ANSIBLE_PLAYBOOK) vault.yml --tags unseal
