# Vault-issued AWS credentials

Part of this repo's exploration of bridging RKE2 workload identity into AWS IAM/STS — see the [main README](../README.md) for cluster prerequisites and bootstrap steps.

An independent path for pods to get scoped AWS credentials, evaluated
alongside IRSA: a standalone HashiCorp Vault instance brokers the
credentials instead of AWS STS federating directly. Pods authenticate to
Vault via its Kubernetes auth method (using their own ServiceAccount token -
no OIDC discovery document, no public S3 bucket needed for this path at
all), and Vault's AWS secrets engine hands back short-lived credentials by
assuming an IAM role using *Vault's own* AWS identity (its EC2 instance
profile, via IMDS - never a static access key).

**Entirely opt-in and off by default** - the Vault instance and everything in
[`terraform/vault.tf`](../terraform/vault.tf) is gated behind `enable_vault`
(default `false`), so a plain `make bootstrap-k8s`/`terraform apply` with no
overrides doesn't create any of it. Set `enable_vault = true` in
`terraform.tfvars` (or `-var enable_vault=true`) before bootstrapping to turn
it on - see [terraform.tfvars.example](../terraform/terraform.tfvars.example).
It lives in the main `terraform/` root rather than `terraform-vault/` even
though it's optional - see the "why not `terraform-vault/`" note further
down for the reasoning.

Extra prerequisites beyond the ones in the [main README](../README.md#prerequisites): **Terraform >= 1.10**
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
Terraform root, [`terraform-vault/`](../terraform-vault/), owns all ongoing
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
  Vault's own PKI - see [`terraform-vault/`](../terraform-vault/) below for
  what that'd take to add later).
- **Vault-issued test role** (`vault_test_role_arn` output) - trusts the
  Vault instance's own IAM role via a plain `sts:AssumeRole` (not
  federated/web-identity - Vault itself is the caller), scoped to only the
  test bucket below.
- **Test bucket** (`vault_test_bucket_name` output) - private bucket used
  purely to prove the Vault credential chain works end to end.
- **`vault-auth-delegator` ServiceAccount** ([manifests/vault-k8s-auth.yaml](../manifests/vault-k8s-auth.yaml))
  - Vault runs outside the cluster, so it can't use an in-cluster identity
  as the Kubernetes auth method's TokenReview caller the way an in-cluster
  Vault would; this ServiceAccount (bound to `system:auth-delegator`) fills
  that role instead.

## Bootstrap sequence

Set `enable_vault = true` in `terraform.tfvars` first (see above) - without
it, `bootstrap-k8s` won't provision the Vault instance at all and
`bootstrap-vault` has nothing to install onto.

```sh
make bootstrap-k8s   # if not already done - provisions the Vault instance alongside the cluster
make bootstrap-vault # everything else - see below
```

Or, for the whole stack from nothing in one go: `make bootstrap-all`.

`bootstrap-vault` ([scripts/bootstrap-vault.sh](../scripts/bootstrap-vault.sh))
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

## Manual verification (no Vault Agent Injector)

[manifests/vault-test.yaml](../manifests/vault-test.yaml) creates a
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

## Vault Agent Injector (real sidecar, real `credential_process` rotation)

`manifests/vault-test.yaml` above fetches credentials once and writes a
static file - proves the mechanics, but structurally can't rotate (most
AWS SDKs cache a plain `AWS_SHARED_CREDENTIALS_FILE` for the client's
lifetime and never notice the file changed). Real rotation needs
`credential_process` instead, since the SDK tracks its `Expiration` field
and knows when to re-invoke it - which needs something that keeps
re-fetching before the lease expires. That's what the **Vault Agent
Injector** (a mutating admission webhook, from the same `hashicorp/vault`
Helm chart used for the server) provides. See
[aws-sdk-credential-caching.md](aws-sdk-credential-caching.md) for
the research behind that caching claim (per-SDK sources, the
per-process/long-lived-client nuance) and a live rig
(`manifests/vault-agent-config-raw.yaml` +
`manifests/vault-test-rotation-proof.yaml`) that proves it directly: the
`aws` CLI, a long-lived `boto3` session, and a long-lived `aws-sdk-go-v2`
client all pointed at the same naively-injected file across a real
rotation.

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

[manifests/vault-test-injector.yaml](../manifests/vault-test-injector.yaml)
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
[manifests/vault-agent-config.yaml](../manifests/vault-agent-config.yaml)
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
described below), so the same restricted-`envsubst` caveat from the IRSA doc's
verification steps and this doc's own hand-wired-Vault section applies here
too - only more so, since this file
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
[vault-agent-template-functions.md](vault-agent-template-functions.md)
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

### Packaged as a Helm chart

[charts/vault-agent-aws-creds](../charts/vault-agent-aws-creds) wraps the exact
same ConfigMap (the HCL/shell content is unchanged, only its packaging is
different) as a reusable Helm chart, for when hand-editing
`manifests/vault-agent-config.yaml` and `envsubst`-ing it stops scaling -
e.g. an app's own chart wanting this as a proper `dependencies:` entry.
Both approaches are kept in this repo side by side: the raw manifest above
as the from-scratch reference (worth reading once to see exactly what an
injector `agent-configmap` needs), the chart for actually consuming it.

Two design points worth knowing before editing the chart:

- The Consul-Template snippet and the shell `command` hook live as real
  `.hcl`/`.sh` files under the chart's `files/` directory, included via
  `.Files.Get` - deliberately **not** `tpl`'d, since the snippet's own
  `{{ .Data.access_key }}` syntax would collide with Helm's identical
  `{{ }}` delimiter if Helm tried to parse it as its own directive. The one
  genuinely-variable piece inside that static file - the AWS secrets engine
  role in `secret "aws/creds/<role>"` - is swapped in via a plain
  placeholder token (`__AWS_SECRETS_ROLE__`) and Sprig's `replace`, the same
  placeholder-substitution style already used for the epoch workaround
  inside the snippet itself, not by templating the file's own content.
- The chart is designed to be included more than once as an aliased
  dependency (Helm's `alias:` in a parent `Chart.yaml`) - the expected case
  is an application chart with several sub-services (several pods), each
  needing its own AWS role; a single pod needing more than one role at once
  is also possible the same way, just less common. Either way, each alias
  gets its own `values` block (distinct `configMapName` and
  `awsSecretsRole`) and renders its own independent ConfigMap. Confirmed
  with a throwaway parent chart aliasing this one twice: two ConfigMaps,
  two distinct `secret "aws/creds/<role>"` paths, no collision.
- Like the raw manifest, this chart only handles the Kubernetes-side half
  (the ConfigMap and its content) - it never creates the Vault auth
  role/policy or the AWS IAM role, those are assumed to already exist
  (`vaultAuthRole`/`awsSecretsRole` chart values reference them by name).
- `vaultAddress` (the HCL `vault { address = ... }` stanza) is optional and
  left unset by default - the chart assumes it's always used alongside the
  Vault Agent Injector, which already sets a `VAULT_ADDR` env var (from its
  own `global.externalVaultAddr`, set once at `make injector-vault` time) on
  every container it mutates. Vault Agent falls back to that env var when
  the stanza is absent entirely, so the default renders no `vault {}` block
  at all rather than an empty one - confirmed live. Set `vaultAddress`
  explicitly only to pin a release to a different Vault address than the
  injector's own default.

Validate offline first - no live cluster or Vault needed:

```sh
helm lint charts/vault-agent-aws-creds
helm template test charts/vault-agent-aws-creds \
  --set namespace=vault-test \
  --set vaultAuthRole=vault-test \
  --set awsSecretsRole=vault-test
```

Then install it in place of the `envsubst | kubectl apply` step above:

```sh
helm upgrade --install vault-agent-aws-creds-config charts/vault-agent-aws-creds \
  --kubeconfig kubeconfig \
  --namespace vault-test \
  --set configMapName=vault-agent-aws-creds-config \
  --set vaultAuthRole=vault-test \
  --set awsSecretsRole=vault-test
```

then apply `manifests/vault-test-injector.yaml` as before - the pod's two
annotations don't change; `agent-configmap` just points at whichever
ConfigMap name the chart rendered. That's `configMapName` above, set
explicitly to match the name `vault-test-injector.yaml` already has
hardcoded in its `agent-configmap` annotation - left unset, the chart
defaults to `<release-name>-vault-agent-aws-creds-config` instead (so with
the release name used here, the unset default would double up to
`vault-agent-aws-creds-config-vault-agent-aws-creds-config`).

**Confirmed live** (2026-08-22, same cluster/Vault version as the
hand-authored path above): chart-rendered credentials pass
`aws sts get-caller-identity`, S3 access is scoped correctly in both
directions (allowed on the vault-test bucket, denied on the IRSA one), and
automatic rotation works identically to the hand-authored version -
`AccessKeyId` changes after the lease TTL with the pod's restart count
staying at `0`. Re-verified with `vaultAddress` unset entirely (the
default): same result, `VAULT_ADDR` supplied by the injector alone.

## Not yet done

- **TLS/PKI for Vault's own listener** - currently `tls_disable = 1`
  (see above). `lab-iac-vault`'s `vault_pki` role has a self-signed
  bootstrap that could be ported if/when this matters.

