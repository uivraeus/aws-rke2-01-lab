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
- **`kube-apiserver`** - `make bootstrap-k8s`/`make ansible-k8s` configure it with
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

1. Open the tunnel (`make tunnel-k8s`, in its own shell), then render and apply
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
full `destroy-k8s`/`apply-k8s` cycle mints a new suffix - new bucket, new
issuer URL, new provider ARN - and `make bootstrap-k8s` re-wires everything to
match automatically, so this is self-consistent within this repo. It only
bites if something *outside* this Terraform (e.g. a role created by hand in
the AWS console) references the old issuer URL or provider ARN directly.

## Vault-issued AWS credentials (evaluated as a second, independent path)

A second, independent path for pods to get scoped AWS credentials, evaluated
alongside IRSA above: a standalone HashiCorp Vault instance brokers the
credentials instead of AWS STS federating directly. Pods authenticate to
Vault via its Kubernetes auth method (using their own ServiceAccount token -
no OIDC discovery document, no public S3 bucket needed for this path at
all), and Vault's AWS secrets engine hands back short-lived credentials by
assuming an IAM role using *Vault's own* AWS identity (its EC2 instance
profile, via IMDS - never a static access key).

**Entirely opt-in and off by default** - the Vault instance and everything in
[`terraform/vault.tf`](terraform/vault.tf) is gated behind `enable_vault`
(default `false`), so a plain `make bootstrap-k8s`/`terraform apply` with no
overrides doesn't create any of it. Set `enable_vault = true` in
`terraform.tfvars` (or `-var enable_vault=true`) before bootstrapping to turn
it on - see [terraform.tfvars.example](terraform/terraform.tfvars.example).
It lives in the main `terraform/` root rather than `terraform-vault/` even
though it's optional - see the "why not `terraform-vault/`" note further
down for the reasoning.

Extra prerequisites beyond the ones listed above: **Terraform >= 1.10**
(`terraform-vault/`'s AppRole credentials use `ephemeral` variables, a 1.10+
feature - the main `terraform/` root still only needs >= 1.7), the
`hashicorp/vault` provider (pulled in automatically by `terraform init`),
`jq` on your machine (used by `scripts/bootstrap-vault.sh` to read `local/vault-*.json`),
`bash` (the scripts under `scripts/` aren't POSIX-`sh`-portable), and
[`helm`](https://helm.sh/docs/intro/install/) if you also want the Vault Agent
Injector (see below) - not needed for the base Vault path.

The Ansible/Terraform split follows
[uivraeus/lab-iac-vault](https://github.com/uivraeus/lab-iac-vault)'s
`02-tf-heavy` approach: Ansible only does what can't be declarative
(install, init, unseal, bootstrap a `terraform-operator` AppRole); a second
Terraform root, [`terraform-vault/`](terraform-vault/), owns all ongoing
Vault configuration (the Kubernetes auth method, the AWS secrets engine)
via the `hashicorp/vault` provider.

**Why the instance itself lives in `terraform/vault.tf`, not
`terraform-vault/`:** `terraform-vault/` only knows the `hashicorp/vault`
provider, which talks to an *already-running* Vault server - it can't
provision the EC2 instance that becomes that server. And even a
multi-provider `terraform-vault/` (adding `aws` alongside `vault`) wouldn't
remove the need for Ansible in between: the `vault` provider's connection
details are only valid after Ansible installs/initializes/unseals Vault and
creates its AppRole, and a single `terraform apply` can't pause partway
through for that. Given the instance needs Ansible regardless of which root
it's declared in, it lives with the AWS infra it's actually entangled with
(shared VPC/subnet/AMI data sources, a security group with rules that
reference the cluster's security group directly, the same tagging the
dynamic Ansible inventory already relies on) rather than introducing a third
root (or cross-root `terraform_remote_state` lookups) for one instance.

What gets provisioned when `enable_vault = true`:

- **Standalone Vault instance** (`vault_instance_id`/`vault_private_ip`
  outputs) - its own EC2 instance, security group (reachable from the
  cluster on 8200 only, no internet ingress), and IAM role. `storage
  "file"` persists across restarts on the root volume; the listener runs
  with `tls_disable = 1` (the instance already isn't internet-reachable,
  and this evaluation is about the credential-issuance mechanics, not
  Vault's own PKI - see [`terraform-vault/`](terraform-vault/) below for
  what that'd take to add later).
- **Vault-issued test role** (`vault_test_role_arn` output) - trusts the
  Vault instance's own IAM role via a plain `sts:AssumeRole` (not
  federated/web-identity - Vault itself is the caller), scoped to only the
  test bucket below.
- **Test bucket** (`vault_test_bucket_name` output) - private bucket used
  purely to prove the Vault credential chain works end to end.
- **`vault-auth-delegator` ServiceAccount** ([manifests/vault-k8s-auth.yaml](manifests/vault-k8s-auth.yaml))
  - Vault runs outside the cluster, so it can't use an in-cluster identity
  as the Kubernetes auth method's TokenReview caller the way an in-cluster
  Vault would; this ServiceAccount (bound to `system:auth-delegator`) fills
  that role instead.

### Bootstrap sequence

Set `enable_vault = true` in `terraform.tfvars` first (see above) - without
it, `bootstrap-k8s` won't provision the Vault instance at all and
`bootstrap-vault` has nothing to install onto.

```sh
make bootstrap-k8s   # if not already done - provisions the Vault instance alongside the cluster
make bootstrap-vault # everything else - see below
```

Or, for the whole stack from nothing in one go: `make bootstrap-all`.

`bootstrap-vault` ([scripts/bootstrap-vault.sh](scripts/bootstrap-vault.sh))
runs the full sequence: install Vault, `operator init` (+ first unseal),
create the `terraform-operator` AppRole, apply the `vault-auth-delegator`
manifest and mint its token, then configure Vault itself (Kubernetes auth
method + AWS secrets engine) via `terraform-vault` (`terraform init` for
that root happens automatically too). It opens its own short-lived SSM
tunnels for the steps that need one (the kubectl step, then the
`terraform-vault apply`) and closes them afterward - no second shell
required.

It writes the root token/unseal keys to a `local/vault-*.json` file and the
AppRole credentials to `local/terraform-operator-*.env` (both gitignored -
never commit these; the exact filenames depend on how the dynamic inventory
names the host, hence the globs). If you need to inspect the root token
directly: `jq -r .root_token local/vault-*.json`.

### Manual verification (no Vault Agent Injector)

[manifests/vault-test.yaml](manifests/vault-test.yaml) creates a
Namespace, ServiceAccount, and a pod with an `initContainer` that does by
hand what a Vault Agent sidecar would normally do automatically: log in via
the Kubernetes auth method using the pod's own (default) ServiceAccount
token, read AWS credentials from `aws/creds/vault-test` once, and write
them as a standard AWS shared-credentials file for the `aws-cli` container
to pick up.

1. Open the tunnel (`make tunnel-k8s`, in its own shell). `tunnel-vault`
   isn't needed for any of this - `VAULT_ADDR` in the next step becomes the
   *pod's own* env var, which the initContainer uses to reach Vault directly
   over the VPC (`vault_private_ip:8200`, permitted by the
   `vault_from_cluster` security group rule); none of these verification
   steps talk to Vault from your machine directly, only kube-apiserver.

2. Render and apply the manifest:

   ```sh
   export VAULT_ADDR="http://$(terraform -chdir=terraform output -raw vault_private_ip):8200"
   export TEST_BUCKET_NAME=$(terraform -chdir=terraform output -raw vault_test_bucket_name)
   export AWS_REGION=$(terraform -chdir=terraform output -raw aws_region)
   envsubst < manifests/vault-test.yaml | kubectl --kubeconfig kubeconfig apply -f -
   ```

3. Confirm the pod actually assumed the role via Vault:

   ```sh
   kubectl --kubeconfig kubeconfig exec -n vault-test -it vault-test -- aws sts get-caller-identity
   ```

   The `Arn` in the response should be
   `arn:aws:sts::<account_id>:assumed-role/<vault_test role name>/...`.

4. Confirm the IAM policy scoping by hitting the test bucket (same
   `$TEST_BUCKET_NAME`-must-expand-inside-the-container caveat as the IRSA
   steps above applies here too):

   ```sh
   kubectl --kubeconfig kubeconfig exec -n vault-test -it vault-test -- sh -c 'aws s3 ls s3://$TEST_BUCKET_NAME/'
   kubectl --kubeconfig kubeconfig exec -n vault-test -it vault-test -- sh -c \
     'echo hello > /tmp/f && aws s3 cp /tmp/f s3://$TEST_BUCKET_NAME/f && aws s3 ls s3://$TEST_BUCKET_NAME/'
   ```

5. Confirm scoping the other way too - the same pod should get
   `AccessDenied` against the *IRSA* test bucket, proving the Vault-issued
   role is actually scoped and not accidentally broad:

   ```sh
   IRSA_TEST_BUCKET=$(terraform -chdir=terraform output -raw irsa_test_bucket_name)
   kubectl --kubeconfig kubeconfig exec -n vault-test -it vault-test -- sh -c \
     "aws s3 ls s3://$IRSA_TEST_BUCKET/"
   ```

Success on steps 3-5 confirms the full chain: Kubernetes auth method
validates the pod's own token -> AWS secrets engine assumes the scoped
role using Vault's own instance-profile credentials -> the pod ends up
with exactly the intended S3 access, nothing more.

### Vault Agent Injector (real sidecar, real `credential_process` rotation)

`manifests/vault-test.yaml` above fetches credentials once and writes a
static file - proves the mechanics, but structurally can't rotate (most
AWS SDKs cache a plain `AWS_SHARED_CREDENTIALS_FILE` for the client's
lifetime and never notice the file changed). Real rotation needs
`credential_process` instead, since the SDK tracks its `Expiration` field
and knows when to re-invoke it - which needs something that keeps
re-fetching before the lease expires. That's what the **Vault Agent
Injector** (a mutating admission webhook, from the same `hashicorp/vault`
Helm chart used for the server) provides.

```sh
make injector-vault
```

Installs the injector only (`server.enabled=false`) pointed at this
cluster's external Vault instance (`global.externalVaultAddr`) - no
in-cluster Vault server, no cert-manager (the injector auto-generates its
own webhook TLS cert by default). Reachability already works via the same
`vault_from_cluster` security group rule the hand-wired test uses.

`terraform-vault/modules/aws`'s `default_sts_ttl` (root `terraform-vault`
variable, **900s by default** - AWS STS's own hard floor for `AssumeRole`,
Vault can't go lower) keeps leases short so rotation is actually
observable without a long wait. Raise it back toward AWS's own default
(3600s) once you're done evaluating rotation itself.

[manifests/vault-test-injector.yaml](manifests/vault-test-injector.yaml)
is the same idea as the hand-wired pod, but with **no
`initContainers`/sidecar in the spec at all** - just two annotations:

```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/agent-configmap: "vault-agent-aws-creds-config"
```

The injector mutates the pod at admission time, adding a `vault-agent-init`
container (renders before the app starts) and a long-running `vault-agent`
sidecar that keeps re-rendering. Everything else - the Consul-Template
snippet, the Sprig-function workaround, the atomic-write command hook (all
described below) - lives in
[manifests/vault-agent-config.yaml](manifests/vault-agent-config.yaml)
instead of the pod spec. That's the actual point of `agent-configmap`
([annotation reference](https://developer.hashicorp.com/vault/docs/platform/k8s/injector/annotations)):
an app developer adding these two lines to their own pod never needs to see
any of that. It's not just the two `agent-inject-template-*`/
`agent-inject-command-*` annotations relocated, though - `agent-configmap`
replaces the injector's *entire* auto-generated Vault Agent config with a
hand-written one (`auto_auth`, `sink`, `vault`, `template` stanzas, as two
full HCL files - `config-init.hcl`/`config.hcl`, picked apart by the
injector using those exact names, identical except `exit_after_auth`).
**Confirmed live**: worked on the first attempt once written against
[HashiCorp's own ConfigMap example](https://developer.hashicorp.com/vault/docs/platform/k8s/injector/examples)
rather than freehand, using HCL heredoc syntax (`<<EOT ... EOT`) for the
`contents`/`command` fields specifically to avoid triple-nested quote
escaping (HCL string quotes containing Go-template quotes containing
shell-script quotes) - a heredoc needs no escaping for its body text at all.

The ConfigMap must exist in the same namespace as any pod referencing it
(ConfigMaps aren't cluster-scoped) and must be applied first. Its own HCL
contains real shell variables (`$epoch`/`$exp`, same as the command hook
described below), so the same restricted-`envsubst` caveat from the IRSA/
hand-wired-Vault sections applies here too - only more so, since this file
mixes three different variable-expansion timings at once (envsubst -
`${VAULT_PRIVATE_IP}`, Go-template - `{{ ... }}`, and the shell script's own
`$epoch`/`$exp`) and only the first one should ever be touched at apply
time:

```sh
export VAULT_PRIVATE_IP=$(terraform -chdir=terraform output -raw vault_private_ip)
envsubst '${VAULT_PRIVATE_IP}' < manifests/vault-agent-config.yaml | kubectl --kubeconfig kubeconfig apply -f -
export TEST_BUCKET_NAME=$(terraform -chdir=terraform output -raw vault_test_bucket_name)
export AWS_REGION=$(terraform -chdir=terraform output -raw aws_region)
envsubst '${TEST_BUCKET_NAME} ${AWS_REGION}' < manifests/vault-test-injector.yaml | kubectl --kubeconfig kubeconfig apply -f -
```

Then the same `aws sts get-caller-identity` check as before
(`vault-test-injector` instead of `vault-test`) confirms the chain works.
To see the actual rendered credentials Vault Agent is maintaining:

```sh
kubectl --kubeconfig kubeconfig -n vault-test exec vault-test-injector -c aws-cli -- cat /vault/secrets/aws-creds
```

**Proving rotation** (confirmed live): note the `AccessKeyId`, then either
wait past the 900s TTL or force it early via Vault's revoke-prefix API
(through `make tunnel-vault`) -
`curl -X PUT -H "X-Vault-Token: $VAULT_ROOT_TOKEN" http://localhost:8200/v1/sys/leases/revoke-prefix/aws/creds/vault-test`
- and `cat` the file again without restarting the pod. One caveat found
this way: forcing revocation does *not* trigger an immediate re-fetch -
`assumed_role` AWS credentials aren't renewable (`Renewable: false` on the
secret), so Vault Agent's template runner just waits out the original
lease duration rather than reacting to the out-of-band revocation. Waiting
out the natural TTL confirmed the real behavior: `AccessKeyId` changed
automatically, pod restart count stayed at `0`, and the new credentials
worked immediately - the actual point of all of this.

**Vault Agent template caveat, confirmed live**: this Vault Agent build
(chart `hashicorp/vault` 0.34.1, app version 2.0.4) has no date-formatting
functions registered (bare or `sprig_`-prefixed) - despite general Consul
Template docs describing `sprig_*`-prefixed functions as available, every
one tried (`sprig_now`, `sprig_date`, `timeAdd`) errored as undefined
against this actual cluster. `manifests/vault-agent-config.yaml` works
around it: the template renders the `Expiration` as a raw Unix-epoch value
wrapped in a placeholder, and a post-render `command` hook (a separate
Vault Agent feature, unrelated to the templating language) converts it to
RFC3339 with `date`/`sed`, both present in the sidecar's own image. If a
future chart version registers these functions, the workaround could be
replaced with a template one-liner - and since it's now confined to the
shared ConfigMap, that'd be a one-place fix instead of a per-pod one.
[docs/vault-agent-template-functions.md](docs/vault-agent-template-functions.md)
traces this to its root cause (Consul Template's Sprig integration only
registers Sprig's *Hermetic* function map, which deliberately excludes
every date/time and random function - non-date Sprig functions like
`sprig_upper` work fine) and catalogs what else is/isn't registered
(`env`/`mustEnv`/`envOrDefault` included), confirmed live against the same
chart/version.

**Atomicity of the SDK-facing file, also confirmed live**: rendering the
placeholder directly to the same file the SDK reads would leave a real
(if brief) window on every rotation where `credential_process` could read
a half-fixed-up file - Vault Agent's own render is atomic (temp file +
rename), but the `command` hook's fix-up is a *separate* write after that,
so two atomic writes with a gap between them still expose the
intermediate, invalid-`Expiration` state in between. The ConfigMap instead
renders the placeholder to a separate `aws-creds-raw` file the SDK never
reads, and the `command` hook writes the final, fully-valid JSON straight
to a temp file and `mv`s it over `/vault/secrets/aws-creds` - the *only*
write that path ever gets, so any reader always sees either the previous
complete credentials or the new ones, never an in-between state. (Checked
live that this image's `sed -i` is itself already safe in isolation - it
writes to a temp file and renames rather than mutating in place, confirmed
by the file's inode changing across an edit - but that only protects each
write individually, not the gap between two separate writes to the same
path, which is the actual problem this restructuring solves.)

### Not yet done

- **TLS/PKI for Vault's own listener** - currently `tls_disable = 1`
  (see above). `lab-iac-vault`'s `vault_pki` role has a self-signed
  bootstrap that could be ported if/when this matters.

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
