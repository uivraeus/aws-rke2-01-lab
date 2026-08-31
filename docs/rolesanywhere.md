# AWS Roles Anywhere

Part of this repo's exploration of bridging RKE2 workload identity into AWS IAM/STS — see the [main README](../README.md) for cluster prerequisites and bootstrap steps.

A third, independent path for pods to get scoped AWS credentials, evaluated
alongside IRSA and Vault. Roles Anywhere is fundamentally different from
both: it authenticates callers via **X.509 client certificates** presented
against a registered CA ("Trust Anchor"), not a Kubernetes-native token -
IRSA uses the cluster's own OIDC-issued ServiceAccount token, Vault uses that
same token via its Kubernetes auth method, but pods have no built-in X.509
identity at all. **[cert-manager](https://cert-manager.io/)** (already a
repo dependency - see [irsa.md](irsa.md)'s `make cert-manager` prerequisite
for the pod-identity webhook) is the bridge here: it issues short-lived,
per-workload leaf certificates from a self-signed root CA that Terraform
also registers directly with AWS as the Roles Anywhere Trust Anchor.

Unlike IRSA or EKS Pod Identity, AWS has never published an official "Roles
Anywhere for Kubernetes" integration - there's no equivalent of
`amazon-eks-pod-identity-webhook` for this path. So unlike the other two
docs in this series, there's no single "the way AWS intends this to work"
to defer to for the Kubernetes-specific parts (issuing/mapping per-pod
certificates); the convention below is this repo's own answer to that,
chosen deliberately rather than copied from a spec.

**Entirely opt-in and off by default** - everything in
[`terraform/rolesanywhere.tf`](../terraform/rolesanywhere.tf) is gated
behind `enable_rolesanywhere` (default `false`), independent of
`enable_vault`. Set `enable_rolesanywhere = true` in `terraform.tfvars` (or
`-var enable_rolesanywhere=true`) before bootstrapping - see
[terraform.tfvars.example](../terraform/terraform.tfvars.example).

What gets provisioned when `enable_rolesanywhere = true`:

- **Self-signed root CA** (`tls_private_key`/`tls_self_signed_cert`, no
  outputs of their own beyond the two below) - free, unlike AWS Private CA
  (~$400/month minimum charge, wildly disproportionate for a throwaway lab).
  Its cert (`rolesanywhere_ca_cert_pem` output) and key
  (`rolesanywhere_ca_key_pem` output, sensitive) both get loaded into
  cert-manager separately - see "Bootstrap sequence" below.
- **Roles Anywhere trust anchor** (`rolesanywhere_trust_anchor_arn` output)
  - registers that CA's certificate with AWS as a `CERTIFICATE_BUNDLE`
    source.
- **Roles Anywhere profile** (`rolesanywhere_profile_arn` output) - the set
  of role(s) a session against this trust anchor may assume, with
  `duration_seconds` (`rolesanywhere_sts_duration_seconds` var, default
  `900`, AWS's own floor) kept short.
- **Roles Anywhere test role** (`rolesanywhere_role_arn` output) - trusts
  `rolesanywhere.amazonaws.com` via `sts:AssumeRole` + `sts:TagSession` +
  `sts:SetSourceIdentity`, scoped to sessions from this trust anchor whose
  certificate carries one specific `workload-id://` URI SAN (see below), with
  access to only the test bucket below. `sts:SetSourceIdentity` isn't
  optional in practice, despite reading like it might only matter if you
  care about source identity - Roles Anywhere always sets one (from the
  certificate's Subject CN), so a trust policy missing this action fails
  every `AssumeRole` with a generic `AccessDeniedException: Unable to assume
  role for <arn>` (confirmed live - it gives no hint that source identity is
  the missing piece, and the error is identical to what a wrong/missing
  `PrincipalTag` condition produces).
- **Test bucket** (`rolesanywhere_test_bucket_name` output) - private
  bucket used purely to prove the Roles Anywhere chain works end to end.

## The `workload-id://` convention

Each Roles Anywhere IAM role needs a trust-policy condition that scopes it
to exactly one certificate identity - the same job IRSA's `sub`-claim
condition does in [`irsa.tf`](../terraform/irsa.tf). Roles Anywhere can
populate a session's principal tags from the presented certificate's
Subject/SAN fields once `sts:TagSession` is granted, so any of those fields
can be used as the condition variable
(`aws:PrincipalTag/x509Subject/CN`, `.../x509Subject/O`,
`.../x509SAN/URI`, ...) - there's no single required field, which is
exactly why this needed a deliberate choice.

**This mapping is not actually automatic**, despite AWS's own docs
describing default rules that include `x509SAN`'s `URI` specifier
(confirmed live: a freshly created `aws_rolesanywhere_profile` returns
`attributeMappings: null` from `GetProfile`, and `AssumeRole` fails for
every request until the mapping is set explicitly). The `hashicorp/aws`
provider's `aws_rolesanywhere_profile` resource has no argument for this at
all - confirmed against the provider's own source
(`internal/service/rolesanywhere/` only implements `profile.go` and
`trust_anchor.go`) - even though the underlying AWS API, and
CloudFormation's own `AWS::RolesAnywhere::Profile`, both support it; this is
specifically a `hashicorp/aws` coverage gap, not an AWS or Terraform-in-general
limitation. It's a known, filed gap -
[hashicorp/terraform-provider-aws#48211](https://github.com/hashicorp/terraform-provider-aws/issues/48211)
already has an implementation sitting in
[PR #48493](https://github.com/hashicorp/terraform-provider-aws/pull/48493),
stuck only on a maintainer running acceptance tests. Until that ships, this
repo works around it with a `terraform_data` + `local-exec` resource right
after `aws_rolesanywhere_profile` in
[`rolesanywhere.tf`](../terraform/rolesanywhere.tf) (see its own comment for
the reasoning and its real limitation - no drift detection/repair, since a
`local-exec` provisioner has no read step) - delete it once #48211 lands in
a release.

This repo uses a **URI Subject Alternative Name**, shaped like a SPIFFE ID
but under a custom scheme:

```
workload-id://<cluster_name>.internal/ns/<namespace>/sa/<service-account>
```

and each role's trust policy conditions on `aws:PrincipalTag/x509SAN/URI`
matching that exact string
(see `local.rolesanywhere_test_workload_uri` in
[`rolesanywhere.tf`](../terraform/rolesanywhere.tf)).

Why this shape specifically:

- **Why a URI SAN, not the CN.** The real
  [SPIFFE](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/)
  X.509-SVID profile deliberately keeps identity out of the Common Name and
  carries it as a URI SAN instead - CN is meant for a simple human-readable
  name, not a structured, parseable identifier. Following that structure
  (trust-domain + namespace + service-account, as path segments) gives a
  clean, general shape without inventing a new one, and leaves the CN free
  for something human-readable later if needed.
- **Why not the literal `spiffe://` scheme.** A real SPIFFE deployment
  implies a whole stack this repo doesn't have: a Workload API, SPIRE (or
  equivalent) issuing and attesting identities, trust bundle federation, and
  enforcement of the full X.509-SVID certificate profile. What's actually
  here is just a cert-manager `Certificate` with one URI SAN, manually
  requested - using `spiffe://` would claim compliance this setup doesn't
  have. `workload-id://` keeps the structure without the claim.
- **Why one compound URI instead of splitting namespace/SA across separate
  Subject fields (e.g. `O`=namespace, `CN`=service account).** That split
  is more idiomatic X.509 and was seriously considered - it would let a
  role condition on `O` alone for "anything in this namespace" - but the
  URI form composes more naturally with how Kubernetes itself names things
  (`/ns/<namespace>/sa/<name>` mirrors the API path shape) and matches the
  direction the wider ecosystem (SPIFFE/SPIRE,
  [`csi-driver-spiffe`](https://cert-manager.io/docs/usage/csi-driver-spiffe/))
  has actually converged on, for anyone comparing this evaluation against
  real-world practice.

**Worked example - adding a second workload/role**, to show this
generalizes the same way IRSA's `sub`-claim scoping does: say a `billing`
namespace needs its own `reports` ServiceAccount to get its own, differently
-scoped role.

1. No change to the CA, trust anchor, `ClusterIssuer`, or any of the
   Kyverno policies - all are already shared across every namespace.
2. Add a new `aws_iam_role` + trust policy in Terraform, identical in shape
   to `rolesanywhere_test`'s but with
   `aws:PrincipalTag/x509SAN/URI` = `workload-id://<cluster_name>.internal/ns/billing/sa/reports`,
   and whatever permissions that role actually needs. Add that role's ARN
   to the Roles Anywhere profile's `role_arns` (or give it its own profile,
   if session policies/durations should differ).
3. Add the `reports` `ServiceAccount` in the `billing` namespace with two
   annotations - `rke2-lab.internal/rolesanywhere-enabled: "true"` and
   `rke2-lab.internal/rolesanywhere-role-arn: <the new role's ARN>` - and
   nothing else. No `Certificate` to hand-write (the `GeneratingPolicy`
   derives `workload-id://<cluster_name>.internal/ns/billing/sa/reports`
   from the `ServiceAccount`'s own namespace/name), and no `Pod`-level
   wiring to hand-write either (the `MutatingPolicy` injects it, reading
   the role ARN straight off this same annotation - see "Pod-level wiring"
   below).

Nothing about the CA/cert-manager/Kyverno wiring changes as workloads are
added - only a new `aws_iam_role` and a `ServiceAccount` carrying two
annotations, one pair per workload identity. Both the `Certificate` and the
pod wiring are generated, not authored, so nothing here can drift the way a
hand-typed URI (or a hand-typed `--role-arn`) in multiple separate files
once could.

**One more gotcha the URI-SAN-only design above runs into**: Roles Anywhere
does not accept certificates with an empty Subject, even though
[RFC 5280](https://datatracker.ietf.org/doc/html/rfc5280) explicitly permits
one when the SAN extension is present and marked critical, and cert-manager
happily issues exactly that (an empty Subject is what you get from a
`Certificate` with no `commonName`/`subject` set, which is what a
URI-SAN-only identity naturally looks like). AWS's own docs say so plainly -
["Certificates with empty subjects are NOT yet supported"](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/trust-model.html)
- and confirmed live: every `AssumeRole` fails with the same generic
`AccessDeniedException`, even against a fully unconditioned trust policy.
Every `Certificate` in this repo therefore sets a `commonName` purely to
satisfy that constraint - see `rolesanywhere-test.yaml`'s comment on the
field. It plays no role in authorization here; the URI SAN remains the only
thing any trust policy condition actually matches on.

## Automation and a misconfiguration guard (Kyverno)

Two related gaps in the design above, addressed with
[Kyverno](https://kyverno.io/) (CNCF Graduated as of March 2026):

- Every workload still meant hand-writing a `Certificate` (as in the worked
  example above), with its URI SAN typed by hand in two separate places -
  the `Certificate` itself and the matching IAM trust policy condition in
  Terraform - with nothing to stop them drifting apart.
- Nothing stopped a `Certificate` in namespace A from requesting a URI SAN
  claiming namespace B's identity in the first place - cert-manager signs
  whatever `spec.uris` says, with no notion that it should match the
  requesting namespace.

[`manifests/kyverno-rolesanywhere-policies.yaml`](../manifests/kyverno-rolesanywhere-policies.yaml)
has two policies:

- **`GeneratingPolicy`** - watches `ServiceAccount`s for the
  `rke2-lab.internal/rolesanywhere-enabled: "true"` annotation (reusing this
  repo's existing custom annotation prefix from the IRSA pod-identity-webhook,
  see [irsa.md](irsa.md)) and generates a matching `Certificate`
  automatically, deriving the `workload-id://` URI from the ServiceAccount's
  own namespace/name via [`manifests/kyverno-config.yaml`](../manifests/kyverno-config.yaml)'s
  `cluster-config` `ConfigMap` (a `GeneratingPolicy`'s CEL has no way to read
  a Terraform output directly, so the cluster name is bridged across the
  same way `local_file.ansible_terraform_vars` already bridges other
  Terraform values into Ansible). `rolesanywhere-test.yaml`'s `Certificate`
  block is gone as of this policy - only the `ServiceAccount`'s annotation
  remains.
- **`ValidatingPolicy`** - rejects any `Certificate` targeting the
  `rolesanywhere-ca` `ClusterIssuer` whose `spec.uris` doesn't match its own
  namespace. Deliberately scoped to that one `ClusterIssuer` specifically
  (via a `matchConditions` check on `spec.issuerRef.name`), so it can't
  interfere with `pod-identity-webhook`'s own, unrelated self-signed
  cert-manager `Certificate` ([irsa.md](irsa.md)).

**Both target *accidental* misconfiguration - typos, a copy-pasted
`Certificate` with the wrong namespace left in - not a defense against a
deliberate, already-RBAC-authorized attempt to bypass them.** Anyone with
`Certificate`-create RBAC could disable the `ValidatingPolicy` outright, or
delete/recreate a `Secret` across namespaces regardless of what minted it in
the first place - see the note on cert-manager's own `Secret`-based
mechanics under "Not yet done" below for why that residual gap exists
independent of Kyverno entirely, and isn't something an admission-time
policy on `Certificate`/`CertificateRequest` objects can close.

**Current, not deprecated, Kyverno API**: both policies use the CEL-based
`policies.kyverno.io/v1` `GeneratingPolicy`/`ValidatingPolicy` CRDs, not the
older `ClusterPolicy` generate/validate rule style - `ClusterPolicy` was
deprecated in Kyverno 1.17 (Feb 2026), with removal planned for 1.20 (Oct
2026). Kyverno's own Helm install output confirms this independently, unprompted:
*"The legacy kyverno.io policy types are deprecated and will be removed in a
future release. Migrate to their policies.kyverno.io replacements..."*.

**Confirmed live** (2026-08-30, `rke2-lab` in `eu-north-1`): the full chain
- annotate a `ServiceAccount`, `Certificate` appears automatically with the
correct `workload-id://` URI, the pod's `aws sts get-caller-identity` and
scoped S3 access work exactly as they did with the hand-written `Certificate`,
and the `ValidatingPolicy` actually rejects a namespace-mismatched
`Certificate` while leaving one targeting an unrelated issuer untouched.
Two real bugs surfaced getting there, both fixed in
[`kyverno-rolesanywhere-policies.yaml`](../manifests/kyverno-rolesanywhere-policies.yaml)
and explained inline where fixed - flagged here because both produced
misleading signals, the same pattern as the two trust-policy bugs earlier
in this doc:

- **CEL's map index operator throws, it doesn't return false.**
  `object.metadata.annotations['some-key']` errors with `no such key` if the
  map doesn't have that key at all - `has(object.metadata.annotations)`
  only confirms the *map itself* exists, not that this specific key does.
  Every `ServiceAccount` in the cluster without the opt-in annotation
  (`cert-manager`'s own, `kube-system`'s, ...) made the `matchConditions`
  error rather than simply not match, spamming failed `UpdateRequest`s. Fix:
  guard the lookup with `'key' in map` first.
- **Kyverno's `background-controller` (which runs `generate`) has no
  built-in permission for arbitrary CRDs.** The `GeneratingPolicy` reported
  `status.ready: true` - it compiled fine - but every actual generation
  attempt failed with `certificates.cert-manager.io is forbidden`. Its
  `ClusterRole` is deliberately empty and aggregates in anything labeled
  `rbac.kyverno.io/aggregate-to-background-controller: "true"` (see
  `kubectl get clusterrole kyverno:background-controller -o yaml` - an
  `aggregationRule`, no `ClusterRoleBinding` to hunt for), so the fix is a
  small separate `ClusterRole` with that label, not a workaround bolted on
  elsewhere.

**Cleanup on `ServiceAccount` deletion, confirmed live in a follow-up pass**:
deleting the annotated `ServiceAccount` needed two separate fixes to fully
clean up after itself, not one:

- The generated `Certificate` sets `metadata.ownerReferences` pointing at
  the triggering `ServiceAccount` (`uid`/`name`/`kind`), so ordinary
  Kubernetes garbage collection deletes it when the `ServiceAccount` is
  deleted - confirmed live, works because both are always in the same
  namespace (owner references require that).
- That alone left the `Secret` cert-manager wrote for the `Certificate`
  dangling - confirmed live: `ownerReferences` cascades `ServiceAccount` ->
  `Certificate`, but cert-manager doesn't link `Secret` -> `Certificate` by
  default (`enableCertificateOwnerRef: false` is the chart default,
  deliberately - deleting a `Certificate` by itself does *not* delete its
  Secret unless this is turned on). Fixed by setting
  `enableCertificateOwnerRef=true` on the `make cert-manager` Helm install
  (see the `Makefile`'s comment on that target for why this is safe to set
  cluster-wide, including for `pod-identity-webhook`'s own unrelated
  Certificate).

With both in place, deleting a `ServiceAccount` now leaves nothing behind -
confirmed by deleting one and finding neither its `Certificate` nor its
`Secret` still present a few seconds later.

**A related, non-bug gotcha, corrected after a second, more patient live
test**: a `Pod` applied *before* its `Certificate`/`Secret` exists sits at
`Init:0/1` retrying the volume mount (`FailedMount ... secret "..." not
found`). An earlier version of this doc claimed this needed a manual
`kubectl delete pod` to clear, based on giving up after only about a minute
of watching - **that claim was wrong**. Confirmed live with a deliberately
delayed `Secret` (and no pod deletion at all): kubelet's own volume-mount
retry loop backs off between repeated failures on the same pod, so the gap
between attempts grows the longer it's been stuck (observed successive
`FailedMount` events roughly 5 minutes apart late in the backoff, versus
seconds apart early on) - but it does keep retrying, and the pod reached
`Running` on its own within a couple of minutes of the `Secret` actually
existing, no intervention needed. In practice this window rarely opens at
all: with the `GeneratingPolicy`'s RBAC correctly in place (as shipped),
the `Certificate` typically appears within a second or two of the
`ServiceAccount`, well before a freshly-scheduled pod even attempts its
first mount.

### Pod-level wiring (Kyverno `MutatingPolicy`)

The `GeneratingPolicy`/`ValidatingPolicy` above only ever reach the
`Certificate` - the actual pod-level wiring (the `fetch-signing-helper`
initContainer, the `signing-helper`/`aws-config` `emptyDir` volumes, the
`rolesanywhere-tls` `Secret` mount, `AWS_CONFIG_FILE`/`AWS_REGION`) still
had to be hand-written in every `Pod` spec, exactly like
`rolesanywhere-test.yaml`'s. [`manifests/kyverno-rolesanywhere-mutation.yaml`](../manifests/kyverno-rolesanywhere-mutation.yaml)
closes that gap with a `MutatingPolicy` - the same role
`amazon-eks-pod-identity-webhook` already plays for IRSA in this repo
(`docs/irsa.md`), but expressed as a Kyverno CEL policy instead of a
bespoke Go webhook. [`manifests/rolesanywhere-mutation-test.yaml`](../manifests/rolesanywhere-mutation-test.yaml)
is the fully-automated counterpart to `rolesanywhere-test.yaml`, the same
relationship `irsa-webhook-test.yaml` already has to `irsa-test.yaml` -
mutually exclusive, identically-named objects, just two `ServiceAccount`
annotations and a bare `Pod`.

**A second annotation, deliberately not IRSA's `rke2-lab.internal/role-arn`**:
the `MutatingPolicy` fires on
`rke2-lab.internal/rolesanywhere-role-arn: <arn>` (alongside the existing
`rolesanywhere-enabled: "true"`), not IRSA's own `role-arn` key. Reusing
that exact key would be a real collision, not just an inconsistency: both
`irsa-test`/`rolesanywhere-test` paths are commonly installed on the same
cluster side by side (true throughout this whole evaluation), so a
`ServiceAccount` set up purely to test IRSA could accidentally *also*
trigger Roles Anywhere pod mutation if it carried the identical annotation
key. Cluster-wide values (trust anchor ARN, profile ARN, region) come from
the same `cluster-config` `ConfigMap` the `GeneratingPolicy` already reads,
extended with three more keys - the role ARN is the only genuinely
per-workload value, so it's the only one that travels via annotation rather
than the shared `ConfigMap`.

**Confirmed live** (2026-08-31, `rke2-lab-01` in `eu-north-1`): the fully
automated Pod (`rolesanywhere-mutation-test.yaml` - no hand-written
initContainer/volumes/env at all) reached `Running` with every field
correctly injected, `aws sts get-caller-identity` and scoped S3 access
worked exactly as they do with the hand-wired manifest, and the hand-wired
manifest itself still works completely unaffected when applied on its own
(no double-injection, no interference - confirmed by checking it still has
exactly one `fetch-signing-helper` initContainer and exactly its own three
volumes, not two of each).

Getting there took three real, sequential CEL/Kubernetes-API discoveries,
each one only found by an actual `kubectl apply` - the least-precedented
CEL shape used across all three Roles Anywhere Kyverno policies, and it
showed:

1. **`ApplyConfiguration` cannot touch "atomic" fields at all** - a
   Kubernetes API-level restriction, not a Kyverno bug. A container's
   `command` (`[]string`) is one; the first draft tried to set it while
   constructing a brand-new `initContainer` via `patchType:
   ApplyConfiguration`, and the API server rejected the whole `Pod` outright:
   `may not mutate atomic arrays, maps or structs: .spec.initContainers[0].command`.
   Fixed by switching to `patchType: JSONPatch` instead, whose `value` is
   plain JSON with no such restriction.
2. **CEL map/list literals are statically homogeneous - one type for every
   value - unlike JSON.** `{"name": "x", "readOnly": true}` (a string value
   next to a bool one) doesn't type-check on its own, and wrapping the
   *whole* literal in `dyn(...)` doesn't fix it - CEL infers a literal's
   type from its own contents before an outer `dyn()` ever applies. What
   actually works: `dyn(...)` around every individual *value* inside a
   heterogeneous map, so each field is independently dyn-typed rather than
   forcing one concrete type across the whole thing. Needed far more
   pervasively than expected - nearly every value literal in the file.
3. **CEL has no map-merge operator at all.** The natural-looking fix for
   "add fields to an existing container without losing the rest of it" -
   `c + dyn({"volumeMounts": ..., "env": ...})` - passed type-checking
   (`dyn` defers everything to runtime) but failed at actual mutation time
   with `no such overload: _+_`: `+` is defined for
   numbers/strings/bytes/lists in CEL, never for two maps, dyn-typed or
   not. Fixed properly, not worked around: `object.spec.containers.indexOf(c)`
   builds one `JSONPatch` per container per field
   (`/spec/containers/<index>/volumeMounts`, `.../env`), each `add`
   replacing only that one list field with `<existing entries> + <new
   ones>` (list concatenation, which *does* work). No patch path ever
   references `image`/`command`/`ports`/`resources`/anything else, so it's
   structurally impossible for this approach to drop them - confirmed live
   by checking the mutated `aws-cli` container kept its own `command:
   [sleep, infinity]` and its own `TEST_BUCKET_NAME` env var exactly as
   written, alongside the injected ones.

See [`kyverno-rolesanywhere-mutation.yaml`](../manifests/kyverno-rolesanywhere-mutation.yaml)'s
own comments for all three, inline at the fix.

## Bootstrap sequence

Set `enable_rolesanywhere = true` in `terraform.tfvars` first, then:

```sh
make bootstrap-k8s     # if not already done
make tunnel-k8s         # in its own shell, leave it running - the Helm installs below need
                        # `kubectl`/`helm --kubeconfig kubeconfig` to reach the cluster,
                        # which (per the main README) means localhost:6443 tunneled to the
                        # control node, not the internet
make cert-manager       # if not already installed (also needed for irsa.md's webhook)
make kyverno             # if not already installed
```

`make bootstrap-k8s` (`apply-k8s` + `ansible-k8s`) already runs `terraform apply` against
this same `terraform/` root as its first step, so it alone provisions the CA/trust
anchor/profile/test role and registers the `x509SAN`/`URI` attribute mapping (the
`terraform_data` workaround - see "The `workload-id://` convention" above) - no separate
`terraform apply` needed. If the base cluster is already bootstrapped and you're only now
flipping `enable_rolesanywhere` on, run `cd terraform && terraform apply` by itself instead
of the full `make bootstrap-k8s` - it picks up the newly-gated resources without re-running
Ansible/RKE2 install for no reason.

Then load the CA into cert-manager, wire up the Kyverno policies, and apply
the test workload (open `make tunnel-k8s` in another shell first):

```sh
export ROLESANYWHERE_CA_CERT_B64=$(terraform -chdir=terraform output -raw rolesanywhere_ca_cert_pem | base64 -w0)
export ROLESANYWHERE_CA_KEY_B64=$(terraform -chdir=terraform output -raw rolesanywhere_ca_key_pem | base64 -w0)
envsubst '${ROLESANYWHERE_CA_CERT_B64} ${ROLESANYWHERE_CA_KEY_B64}' \
  < manifests/rolesanywhere-ca-issuer.yaml | kubectl --kubeconfig kubeconfig apply -f -

export CLUSTER_NAME=$(terraform -chdir=terraform output -raw cluster_name)
export ROLESANYWHERE_TRUST_ANCHOR_ARN=$(terraform -chdir=terraform output -raw rolesanywhere_trust_anchor_arn)
export ROLESANYWHERE_PROFILE_ARN=$(terraform -chdir=terraform output -raw rolesanywhere_profile_arn)
export AWS_REGION=$(terraform -chdir=terraform output -raw aws_region)
envsubst '${CLUSTER_NAME} ${ROLESANYWHERE_TRUST_ANCHOR_ARN} ${ROLESANYWHERE_PROFILE_ARN} ${AWS_REGION}' \
  < manifests/kyverno-config.yaml | kubectl --kubeconfig kubeconfig apply -f -
kubectl --kubeconfig kubeconfig apply -f manifests/kyverno-rolesanywhere-policies.yaml
kubectl --kubeconfig kubeconfig apply -f manifests/kyverno-rolesanywhere-mutation.yaml
kubectl --kubeconfig kubeconfig get generatingpolicy,validatingpolicy,mutatingpolicy   # all three should show a ready/valid status

export ROLESANYWHERE_ROLE_ARN=$(terraform -chdir=terraform output -raw rolesanywhere_role_arn)
export TEST_BUCKET_NAME=$(terraform -chdir=terraform output -raw rolesanywhere_test_bucket_name)

# Either the hand-wired Pod (all wiring explicit, useful as a reference for what the
# MutatingPolicy is actually doing on your behalf):
envsubst '${ROLESANYWHERE_TRUST_ANCHOR_ARN} ${ROLESANYWHERE_PROFILE_ARN} ${ROLESANYWHERE_ROLE_ARN} ${TEST_BUCKET_NAME} ${AWS_REGION}' \
  < manifests/rolesanywhere-test.yaml | kubectl --kubeconfig kubeconfig apply -f -

# ...or the fully-automated one (mutually exclusive with the above - delete
# `kubectl delete namespace rolesanywhere-test` first if switching):
envsubst '${ROLESANYWHERE_ROLE_ARN} ${TEST_BUCKET_NAME}' \
  < manifests/rolesanywhere-mutation-test.yaml | kubectl --kubeconfig kubeconfig apply -f -
kubectl --kubeconfig kubeconfig -n rolesanywhere-test get certificate rolesanywhere-test   # generated automatically - see below
```

With the `GeneratingPolicy`'s RBAC correctly in place, the `Certificate`
above typically appears within a second or two of the `ServiceAccount`, so
the `Pod` should reach `Running` on its own without any extra steps. If it
briefly shows `Init:0/1` first, that's fine - see "Automation and a
misconfiguration guard" above for why, and why it resolves on its own
without needing a manual pod restart.

The restricted `envsubst '...'` form (an explicit list of names, not a bare
`envsubst`) matters here for the same reason it does in
[vault.md](vault.md#vault-agent-injector-real-sidecar-real-credential_process-rotation):
both manifests embed real shell scripts (the initContainer's
`credential_process` config, the CA issuer's base64 blobs) alongside the
apply-time placeholders, and an unrestricted `envsubst` would happily
"substitute" any other `$name`-shaped token it finds in those scripts too,
using whatever (usually empty) value that name happens to have in your
shell - silently corrupting the script rather than erroring.

**Confirmed live** (2026-08-29, `rke2-lab` in `eu-north-1`): the full chain
below worked end to end - `get-caller-identity` returning the expected
assumed-role ARN, scoped S3 access allowed on the Roles Anywhere test
bucket and denied on the IRSA one, and rotation confirmed via a forced
cert-manager renewal. Getting there took two fixes beyond the trust policy
this doc's Terraform ships (both already folded into
[`rolesanywhere.tf`](../terraform/rolesanywhere.tf) and
[`rolesanywhere-test.yaml`](../manifests/rolesanywhere-test.yaml), and
called out inline above): the `x509SAN`/`URI` attribute mapping, and
`sts:SetSourceIdentity` in the trust policy's actions. Both failures looked
identical from the outside - the same generic
`AccessDeniedException: Unable to assume role for <arn>`, with no signal
pointing at which piece was missing - which is why they're documented as
prominently as the working configuration itself.

## Manual verification

1. Confirm the `Certificate` was actually generated (by the `GeneratingPolicy`,
   from the `ServiceAccount`'s annotation - there's no `Certificate` in
   `rolesanywhere-test.yaml` itself to apply) and issued. Missing entirely
   means the `GeneratingPolicy` didn't fire - check its own status and the
   `ServiceAccount`'s annotation first; present but `Ready: False` means the
   `ClusterIssuer` from the step above isn't in place yet, or the CA
   Secret's `tls.crt`/`tls.key` don't match:

   ```sh
   kubectl --kubeconfig kubeconfig -n rolesanywhere-test get certificate rolesanywhere-test
   ```

2. Confirm the pod actually assumed the role via Roles Anywhere:

   ```sh
   kubectl --kubeconfig kubeconfig exec -n rolesanywhere-test -it rolesanywhere-test -- aws sts get-caller-identity
   ```

   The `Arn` in the response should be
   `arn:aws:sts::<account_id>:assumed-role/<rolesanywhere_role_arn's role name>/...`.

3. Confirm the IAM policy scoping by hitting the test bucket - same
   expand-inside-the-container caveat as the IRSA/Vault docs (an unset local
   variable silently turns `s3://$TEST_BUCKET_NAME/` into `s3://`, which
   calls the very different `s3:ListAllMyBuckets` action):

   ```sh
   kubectl --kubeconfig kubeconfig exec -n rolesanywhere-test -it rolesanywhere-test -- sh -c 'aws s3 ls s3://$TEST_BUCKET_NAME/'
   kubectl --kubeconfig kubeconfig exec -n rolesanywhere-test -it rolesanywhere-test -- sh -c \
     'echo hello > /tmp/f && aws s3 cp /tmp/f s3://$TEST_BUCKET_NAME/f && aws s3 ls s3://$TEST_BUCKET_NAME/'
   ```

4. Confirm scoping the other way too - this role should get `AccessDenied`
   against the IRSA/Vault test buckets, proving it's actually scoped and not
   accidentally broad:

   ```sh
   IRSA_TEST_BUCKET=$(terraform -chdir=terraform output -raw irsa_test_bucket_name)
   kubectl --kubeconfig kubeconfig exec -n rolesanywhere-test -it rolesanywhere-test -- sh -c \
     "aws s3 ls s3://$IRSA_TEST_BUCKET/"
   ```

Success on steps 2-4 confirms the full chain: cert-manager issues a leaf
cert with the expected `workload-id://` URI SAN from the shared root CA ->
Roles Anywhere validates it against the trust anchor and tags the session
with that URI -> the IAM role's trust policy condition matches -> the pod
ends up with exactly the intended S3 access, nothing more.

## Proving rotation

cert-manager's own floor (`duration` >= 1h, `renewBefore` >= 5m) means the
`Certificate` above only renews naturally once an hour - a real constraint,
not a deliberately short window the way Vault's 900s STS TTL is. Rather than
waiting out the hour, force a renewal on demand:

```sh
kubectl --kubeconfig kubeconfig -n rolesanywhere-test delete secret rolesanywhere-test-tls
```

cert-manager notices the Secret is gone and reissues immediately (or use
[`cmctl renew rolesanywhere-test -n rolesanywhere-test`](https://cert-manager.io/docs/reference/cmctl/#renew)
if `cmctl` is installed, which renews in place without deleting the Secret
first). `aws_signing_helper` itself re-reads the certificate/key files fresh
on every invocation - it isn't a daemon caching them in memory - so the very
next `credential_process` invocation signs with the new certificate
automatically. No pod restart, no sidecar analogous to the Vault Agent
Injector needed.

**Confirming this without waiting out the full session duration is trickier
than it sounds** (confirmed live): simply re-running
`aws sts get-caller-identity` right after forcing the renewal still shows
the *old* certificate's identity, because the AWS CLI caches the credentials
`credential_process` returned and won't re-invoke it until they're close to
expiring - this is expected CLI behavior, not a sign rotation didn't work.
The session name in `GetCallerIdentity`'s response is always the
hex-encoded serial number of whichever certificate authenticated it (a
Roles Anywhere convention), so the most direct proof is to bypass the CLI's
cache and invoke the helper directly, twice - once before, once after
forcing renewal:

```sh
kubectl --kubeconfig kubeconfig exec -n rolesanywhere-test -it rolesanywhere-test -- sh -c '
  /opt/bin/aws_signing_helper credential-process \
    --certificate /rolesanywhere/tls.crt --private-key /rolesanywhere/tls.key \
    --trust-anchor-arn '"$ROLESANYWHERE_TRUST_ANCHOR_ARN"' \
    --profile-arn '"$ROLESANYWHERE_PROFILE_ARN"' --role-arn '"$ROLESANYWHERE_ROLE_ARN"' \
    --region '"$AWS_REGION"' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)[\"AccessKeyId\"])"
'
```

Compare the certificate's own serial
(`openssl x509 -noout -serial -in <(kubectl ... get secret rolesanywhere-test-tls -o jsonpath=... | base64 -d)`)
against the session name in a fresh `aws sts get-caller-identity` run using
those exact credentials - they match after rotation, proving the helper
picked up the new certificate, independent of whatever the CLI's own cache
is still holding onto.

## Not yet done

- **Both `Certificate` creation and pod wiring are now automated
  (`GeneratingPolicy` + `MutatingPolicy`, see "Pod-level wiring" above) -
  confirmed live, including that an app's own container fields (`command`,
  `TEST_BUCKET_NAME`, ...) survive the mutation untouched.** They're still
  separate policies with separate failure modes, though - a correctly-issued
  `Certificate` says nothing about whether the `MutatingPolicy` also
  injected correctly. Re-verify both independently after any Kyverno
  upgrade, not just the credential chain end to end.
- **Certificates live in `Secret`s, readable by anyone with ordinary
  Secret-read RBAC - unlike this repo's other two paths.** cert-manager
  always writes the issued key material to a `kubernetes.io/tls` `Secret`
  object. That's fundamentally different from IRSA's projected
  ServiceAccount token (minted by kubelet straight into the pod's own
  ephemeral volume via the TokenRequest API, never persisted to etcd as a
  Secret at all) or Vault's rendered files (`emptyDir`-only, same story) -
  both of those need a live exec into the specific pod (or node/kubelet
  compromise) to extract; a cert-manager `Secret` can be read by anyone with
  `get`/`list` RBAC on Secrets, from anywhere, at any later time, and copied
  into a different namespace's pod entirely - `kubectl get secret ... -o
  yaml | kubectl apply -n other-namespace -f -`. Neither Kyverno policy
  above touches this: the `ValidatingPolicy` only ever sees `Certificate`/
  `CertificateRequest` objects at the moment they're created, not what
  happens to the `Secret` cert-manager writes afterward.
  [`csi-driver-spiffe`](https://cert-manager.io/docs/usage/csi-driver-spiffe/)
  (part of the cert-manager project) closes both this gap and the one above
  at once: a CSI driver that mounts a SPIFFE-identity certificate straight
  into a pod's own node-local filesystem via a volume claim - never a
  Secret object - deriving the identity from the pod's own
  namespace/ServiceAccount automatically, no per-workload YAML at all.
  Adopting it would also mean switching to the literal `spiffe://` scheme
  (its identities *are* real SPIFFE SVIDs), plus running `trust-manager` for
  trust bundle distribution - more infrastructure than this evaluation's
  single test workload currently justifies, but the strongest real answer
  to both open items here.
- **ACM Private CA**, as the paid alternative to the self-signed root here,
  for anyone who eventually needs a trust chain that isn't self-signed
  (e.g. because something outside this cluster also needs to trust it).
