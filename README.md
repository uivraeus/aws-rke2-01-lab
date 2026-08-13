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

## IRSA (IAM Roles for Service Accounts)

Terraform also provisions everything needed for IRSA against this cluster,
even though its control plane isn't publicly reachable - AWS STS needs to
fetch the OIDC discovery document and JWKS over the public internet to
validate tokens, so those get mirrored to a public-but-scoped S3 location
instead (the same pattern kOps and other self-managed IRSA setups use), and
the cluster's OIDC issuer is pointed at that S3 URL.

What's already wired up:

- **OIDC discovery bucket** (`oidc_bucket_name` output) - publicly serves
  only `<cluster_name>/.well-known/openid-configuration` and
  `<cluster_name>/keys.json`; everything else in the bucket stays private.
- **IAM OIDC identity provider** - trusts the S3-hosted issuer URL.
- **`kube-apiserver`** - `make bootstrap`/`make ansible` configure it with
  `--service-account-issuer`/`--service-account-jwks-uri` pointing at that
  bucket (see `ansible/roles/rke2_server`), and mirror the live discovery
  document/JWKS into it right after the node comes up.
- **IRSA verification role** (`irsa_role_arn` output) - assumable via
  `AssumeRoleWithWebIdentity`, scoped to
  `system:serviceaccount:<irsa_namespace>:<irsa_service_account_name>`
  (defaults: `irsa-test`/`irsa-test`), with access to only the test bucket
  below.
- **Test bucket** (`irsa_test_bucket_name` output) - private bucket used
  purely to prove the IRSA chain works end to end.

If the service-account signing key ever rotates (e.g. an RKE2 upgrade) and
IRSA token validation starts failing, re-sync the mirror without re-running
the rest of the playbook:

```sh
make sync-oidc
```

### Manual verification (no webhook)

[manifests/irsa-test.yaml](manifests/irsa-test.yaml) creates a Namespace,
ServiceAccount, and an aws-cli Pod. No pod-identity webhook is installed at
this stage, so the manifest does by hand what the webhook would normally
inject automatically: a projected service-account token for the
`sts.amazonaws.com` audience, mounted at
`/var/run/secrets/eks.amazonaws.com/serviceaccount/token`, plus
`AWS_ROLE_ARN`/`AWS_WEB_IDENTITY_TOKEN_FILE` env vars so the AWS CLI's
default credential chain picks it up.

1. Open the tunnel (`make tunnel`, in its own shell), then render and apply
   the manifest:

   ```sh
   export IRSA_ROLE_ARN=$(terraform -chdir=terraform output -raw irsa_role_arn)
   export TEST_BUCKET_NAME=$(terraform -chdir=terraform output -raw irsa_test_bucket_name)
   export AWS_REGION=$(terraform -chdir=terraform output -raw aws_region)
   envsubst < manifests/irsa-test.yaml | kubectl --kubeconfig kubeconfig apply -f -
   ```

2. Confirm the pod actually assumed the role via
   `AssumeRoleWithWebIdentity`:

   ```sh
   kubectl --kubeconfig kubeconfig exec -n irsa-test -it irsa-test -- aws sts get-caller-identity
   ```

   The `Arn` in the response should be
   `arn:aws:sts::<account_id>:assumed-role/<irsa_role_arn's role name>/...`.

3. Confirm the IAM policy scoping by hitting the test bucket - **expand the
   bucket name inside the container, not in your outer shell** (it's already
   set as `TEST_BUCKET_NAME` in the pod's env from the manifest; expanding an
   unset local variable instead silently turns this into `s3://` with no
   bucket, which calls the very different `s3:ListAllMyBuckets` action and
   fails with `AccessDenied` even though IRSA itself is working fine):

   ```sh
   kubectl --kubeconfig kubeconfig exec -n irsa-test -it irsa-test -- sh -c 'aws s3 ls s3://$TEST_BUCKET_NAME/'
   kubectl --kubeconfig kubeconfig exec -n irsa-test -it irsa-test -- sh -c \
     'echo hello > /tmp/f && aws s3 cp /tmp/f s3://$TEST_BUCKET_NAME/f && aws s3 ls s3://$TEST_BUCKET_NAME/'
   ```

   Success on both confirms the full chain: OIDC discovery mirrored to S3 ->
   IAM OIDC provider trusts it -> `AssumeRoleWithWebIdentity` via the
   projected token -> scoped bucket policy grants exactly the intended
   access.

4. Once this passes, a real pod-identity webhook could be installed so
   `ServiceAccount` annotations alone are enough (no manual volume/env
   wiring per pod) - the ServiceAccount created here is already annotated
   with `eks.amazonaws.com/role-arn` in preparation for that.

**Caveat:** the OIDC bucket's name (and therefore the issuer URL and OIDC
provider ARN) is generated by `random_id` and stored in Terraform state. A
full `terraform destroy`/`apply` cycle mints a new suffix - new bucket, new
issuer URL, new provider ARN - and `make bootstrap` re-wires everything to
match automatically, so this is self-consistent within this repo. It only
bites if something *outside* this Terraform (e.g. a role created by hand in
the AWS console) references the old issuer URL or provider ARN directly.

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
make destroy
```

Destroys everything, including the S3 transfer bucket. Nothing is designed to survive beyond
a single bootstrap/experiment/destroy cycle — there's no upgrade or backup/restore support.
