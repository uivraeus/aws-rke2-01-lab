TF_DIR := terraform
ANSIBLE_DIR := ansible

.PHONY: init fmt validate plan apply ansible-deps ansible bootstrap restart reboot sync-oidc tunnel destroy

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
