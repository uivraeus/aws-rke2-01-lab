# Simple RKE2 deployment in AWS (for fun)

Throwaway [RKE2](https://docs.rke2.io/) cluster in AWS: 1 control node + 1 worker node,
sized and scoped for experiments, not production. Terraform provisions the infrastructure,
Ansible installs and joins RKE2. No SSH keys, no open inbound ports — everything goes over
[AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html).

## Prerequisites

- An AWS account/profile set up for **AWS SSO** login, with permissions to create EC2, IAM,
  and S3 resources in the target region's default VPC.
- Tools on your machine:
  - [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.7
  - [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
    with the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
  - Python 3 (used to create a venv - see below; nothing needs installing into your
    system/user Python)
  - `make`

Ansible itself isn't a prerequisite to install - every Ansible-invoking Make target
depends on `ansible-venv`, which creates/syncs a gitignored `.ansible-venv/` in the repo
root (`ansible`, `boto3`, `botocore`) and every target uses that venv's binaries
directly, regardless of what's on your `PATH`. Run `make ansible-venv` directly if you
want to set it up ahead of time; otherwise it happens automatically on first use.

## One-time setup

```sh
aws sso login --profile <your-profile>

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit terraform.tfvars: set aws_profile and aws_region at least

make init-k8s
make ansible-deps   # installs the amazon.aws / community.aws collections (creates .ansible-venv first if needed)
```

## Bootstrap the cluster

```sh
make bootstrap-k8s   # terraform apply, then runs the Ansible playbook
```

This creates:

- The 2 EC2 instances (control + worker) in the account's default VPC, with an IAM instance
  profile for SSM, and a security group that only allows the two nodes to talk to each other
  (no ports open to the internet).
- A small S3 bucket used purely as the file-transfer channel for Ansible's SSM connection
  plugin.
- `ansible/group_vars/all/terraform.yml`, generated automatically so Ansible knows the bucket
  name, region, profile, and control node's private IP.

Then Ansible installs RKE2 (`stable` channel) on both nodes over SSM, joins the worker to the
control plane, and fetches a working `kubeconfig` to the repo root.

## Using the cluster

RKE2's kubeconfig defaults to `https://127.0.0.1:6443`, so open an SSM port-forward tunnel to
the control node and point `kubectl` at the local end:

```sh
make tunnel-k8s                                # run in its own shell, leave it running
kubectl --kubeconfig kubeconfig get nodes       # in another shell
```

To restart just the RKE2 service (and wait for the node to report `Ready` again):

```sh
make restart                # both nodes
make restart LIMIT=control  # just the control node
make restart LIMIT=worker   # just the worker node
```

To reboot the underlying EC2 instance(s) at the OS level instead:

```sh
make reboot                # both nodes
make reboot LIMIT=control  # just the control node
make reboot LIMIT=worker   # just the worker node
```

Both `rke2-server`/`rke2-agent` are enabled via systemd and RKE2's embedded etcd persists on
the root volume, so service restarts and full instance reboots are expected to come back on
their own - `make reboot` doesn't wait for that, so give it a minute or two and check with
`kubectl get nodes`.

For anything else, get an interactive shell on either node:

```sh
aws ssm start-session --profile <your-profile> --target <instance-id>
```

Instance IDs are in the `terraform output` (or the AWS console/CLI, tagged
`Project=<cluster_name>`).

## Bridging RKE2 workload identity into AWS IAM

RKE2's control plane isn't EKS, so none of the usual "just use IRSA/EKS Pod
Identity" defaults apply for free. Each variant below is a self-contained,
independent exploration of getting pods scoped AWS credentials anyway - pick
the one you care about and follow it end to end without needing the others:

- **[IRSA](docs/irsa.md)** (`terraform/irsa.tf` + the
  amazon-eks-pod-identity-webhook) - AWS STS federates directly against the
  cluster's own (self-hosted) OIDC issuer.
- **[Vault-issued AWS credentials](docs/vault.md)** (`terraform/vault.tf` +
  `terraform-vault/`) - a standalone HashiCorp Vault instance brokers
  credentials instead, using its own AWS identity to assume roles on pods'
  behalf.
- **[AWS Roles Anywhere](docs/rolesanywhere.md)** (`terraform/rolesanywhere.tf`
  + cert-manager) - pods get an X.509 identity from a self-signed CA via
  cert-manager, and AWS Roles Anywhere brokers credentials by validating
  that certificate against a matching trust anchor, instead of a
  Kubernetes-native token.

## Verifying RKE2's service-account key rotation (not IRSA-specific)

Unrelated to IRSA itself, but exercising exactly the "signing key rotation"
scenario `make sync-oidc` exists to recover from:

```sh
make rotate-sa-key
```

This runs
[ansible/rotate_service_account_key.yml](ansible/rotate_service_account_key.yml),
which performs
[RKE2's documented `rotate-ca` procedure](https://docs.rke2.io/security/certificates)
for the service-account signing key specifically (stage a new key + the
current one into `/opt/rke2/server/tls`, `rke2 certificate rotate-ca`,
restart `rke2-server`), then verifies the outcome against what the docs
claim: the pre-rotation key is still present in the published JWKS (so
already-issued tokens keep validating), and a freshly-requested token is
signed with a new key. It asserts both, so a docs/behavior mismatch fails
loudly instead of silently.

If this cluster is wired up for IRSA, follow up with `make sync-oidc` -
this playbook only rotates the live cluster's key, it doesn't touch the
mirrored copy in S3.

## Tearing down

```sh
make destroy-all
```

Destroys everything, including the S3 transfer bucket - and, if the Vault evaluation was
set up, `terraform-vault`'s resources first (Vault's own Kubernetes auth method/AWS
secrets engine config), then the underlying AWS infra, in that order (destroying the AWS
side first would leave `terraform-vault`'s state pointing at a Vault server that no
longer exists). Nothing is designed to survive beyond a single bootstrap/experiment/destroy
cycle — there's no upgrade or backup/restore support.

If you only ever bootstrapped the base cluster/IRSA (never ran `bootstrap-vault`/
`bootstrap-all`), `make destroy-k8s` alone is equivalent and skips the no-op
`destroy-vault` step.
