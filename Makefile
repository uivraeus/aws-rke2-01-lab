TF_DIR := terraform
ANSIBLE_DIR := ansible

.PHONY: init fmt validate plan apply ansible-deps ansible bootstrap restart sync-oidc tunnel destroy

init:
	cd $(TF_DIR) && terraform init

fmt:
	cd $(TF_DIR) && terraform fmt -recursive

validate:
	cd $(TF_DIR) && terraform validate

plan:
	cd $(TF_DIR) && terraform plan

apply:
	cd $(TF_DIR) && terraform apply

ansible-deps:
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml

# Reads connection details from terraform outputs so nothing needs to be copy-pasted by hand.
ansible:
	cd $(ANSIBLE_DIR) && \
	AWS_PROFILE=$$(terraform -chdir=../$(TF_DIR) output -raw aws_profile) \
	AWS_REGION=$$(terraform -chdir=../$(TF_DIR) output -raw aws_region) \
	RKE2_CLUSTER_NAME=$$(terraform -chdir=../$(TF_DIR) output -raw cluster_name) \
	ansible-playbook site.yml

bootstrap: apply ansible

# Restarts rke2-server/rke2-agent and waits for the node(s) to report Ready again.
#   make restart               # both nodes
#   make restart LIMIT=control # just the control node
#   make restart LIMIT=worker  # just the worker node
restart:
	cd $(ANSIBLE_DIR) && \
	AWS_PROFILE=$$(terraform -chdir=../$(TF_DIR) output -raw aws_profile) \
	AWS_REGION=$$(terraform -chdir=../$(TF_DIR) output -raw aws_region) \
	RKE2_CLUSTER_NAME=$$(terraform -chdir=../$(TF_DIR) output -raw cluster_name) \
	ansible-playbook restart.yml $(if $(LIMIT),--limit $(LIMIT))

# Re-syncs the OIDC discovery document/JWKS from the live control node into the OIDC
# bucket, without re-running the rest of the playbook. Use this if IRSA token
# validation starts failing after an RKE2 upgrade rotates the service-account signing
# key - the mirror is only synced automatically during `make bootstrap`/`make ansible`.
sync-oidc:
	cd $(ANSIBLE_DIR) && \
	AWS_PROFILE=$$(terraform -chdir=../$(TF_DIR) output -raw aws_profile) \
	AWS_REGION=$$(terraform -chdir=../$(TF_DIR) output -raw aws_region) \
	RKE2_CLUSTER_NAME=$$(terraform -chdir=../$(TF_DIR) output -raw cluster_name) \
	ansible-playbook site.yml --tags oidc_sync

# Opens an SSM port-forward tunnel so `kubectl --kubeconfig kubeconfig` works from your laptop.
# Run this in its own shell and leave it running.
tunnel:
	cd $(TF_DIR) && eval $$(terraform output -raw tunnel_command)

destroy:
	cd $(TF_DIR) && terraform destroy
