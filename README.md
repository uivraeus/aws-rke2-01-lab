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
  - Python 3 with `boto3`/`botocore` (`pip install boto3 botocore`), plus
    [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html)
  - `make`

## One-time setup

```sh
aws sso login --profile <your-profile>

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit terraform.tfvars: set aws_profile and aws_region at least

make init
make ansible-deps   # installs the amazon.aws / community.aws collections
```

## Bootstrap the cluster

```sh
make bootstrap   # terraform apply, then runs the Ansible playbook
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
make tunnel                                    # run in its own shell, leave it running
kubectl --kubeconfig kubeconfig get nodes       # in another shell
```

To get an interactive shell on either node (e.g. to `systemctl restart rke2-server`,
`systemctl restart rke2-agent`, or reboot and watch it recover):

```sh
aws ssm start-session --profile <your-profile> --target <instance-id>
```

Instance IDs are in the `terraform output` (or the AWS console/CLI, tagged
`Project=<cluster_name>`). Both services are enabled via systemd and RKE2's embedded etcd
persists on the root volume, so service restarts and full instance reboots are expected to
come back on their own.

## Tearing down

```sh
make destroy
```

Destroys everything, including the S3 transfer bucket. Nothing is designed to survive beyond
a single bootstrap/experiment/destroy cycle — there's no upgrade or backup/restore support.
