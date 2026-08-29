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
  `rolesanywhere.amazonaws.com` via `sts:AssumeRole` + `sts:TagSession`,
  scoped to sessions from this trust anchor whose certificate carries one
  specific `workload-id://` URI SAN (see below), with access to only the
  test bucket below.
- **Test bucket** (`rolesanywhere_test_bucket_name` output) - private
  bucket used purely to prove the Roles Anywhere chain works end to end.

## The `workload-id://` convention

Each Roles Anywhere IAM role needs a trust-policy condition that scopes it
to exactly one certificate identity - the same job IRSA's `sub`-claim
condition does in [`irsa.tf`](../terraform/irsa.tf). Roles Anywhere
auto-populates a session's principal tags from the presented certificate's
Subject/SAN fields once `sts:TagSession` is granted, so any of those fields
can be used as the condition variable
(`aws:PrincipalTag/x509Subject/CN`, `.../x509Subject/O`,
`.../x509SAN/URI`, ...) - there's no single required field, which is
exactly why this needed a deliberate choice.

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

1. No change to the CA, trust anchor, or `ClusterIssuer` - all three are
   already shared across every namespace.
2. Add a `Certificate` in the `billing` namespace requesting
   `uris: [workload-id://<cluster_name>.internal/ns/billing/sa/reports]`,
   same as `rolesanywhere-test.yaml`'s but with different `metadata.namespace`
   and URI path segments.
3. Add a new `aws_iam_role` + trust policy in Terraform, identical in shape
   to `rolesanywhere_test`'s but with
   `aws:PrincipalTag/x509SAN/URI` = `workload-id://<cluster_name>.internal/ns/billing/sa/reports`,
   and whatever permissions that role actually needs.
4. Add that role's ARN to the Roles Anywhere profile's `role_arns` (or give
   it its own profile, if session policies/durations should differ) - a
   pod authenticates as *a certificate*, and which of the profile's roles it
   actually assumes is chosen at credential-helper invocation time via
   `--role-arn`, same as `rolesanywhere-test.yaml`'s initContainer does.

Nothing about the CA/cert-manager wiring changes as workloads are added -
only new `Certificate`/`aws_iam_role` pairs, one per workload identity.

## Bootstrap sequence

Set `enable_rolesanywhere = true` in `terraform.tfvars` first, then:

```sh
make bootstrap-k8s     # if not already done
cd terraform && terraform apply   # provisions the CA/trust anchor/profile/test role
make cert-manager       # if not already installed (also needed for irsa.md's webhook)
```

Then load the CA into cert-manager and apply the test workload (open
`make tunnel-k8s` in another shell first):

```sh
export ROLESANYWHERE_CA_CERT_B64=$(terraform -chdir=terraform output -raw rolesanywhere_ca_cert_pem | base64 -w0)
export ROLESANYWHERE_CA_KEY_B64=$(terraform -chdir=terraform output -raw rolesanywhere_ca_key_pem | base64 -w0)
envsubst '${ROLESANYWHERE_CA_CERT_B64} ${ROLESANYWHERE_CA_KEY_B64}' \
  < manifests/rolesanywhere-ca-issuer.yaml | kubectl --kubeconfig kubeconfig apply -f -

export CLUSTER_NAME=$(terraform -chdir=terraform output -raw cluster_name)
export ROLESANYWHERE_TRUST_ANCHOR_ARN=$(terraform -chdir=terraform output -raw rolesanywhere_trust_anchor_arn)
export ROLESANYWHERE_PROFILE_ARN=$(terraform -chdir=terraform output -raw rolesanywhere_profile_arn)
export ROLESANYWHERE_ROLE_ARN=$(terraform -chdir=terraform output -raw rolesanywhere_role_arn)
export TEST_BUCKET_NAME=$(terraform -chdir=terraform output -raw rolesanywhere_test_bucket_name)
export AWS_REGION=$(terraform -chdir=terraform output -raw aws_region)
envsubst '${CLUSTER_NAME} ${ROLESANYWHERE_TRUST_ANCHOR_ARN} ${ROLESANYWHERE_PROFILE_ARN} ${ROLESANYWHERE_ROLE_ARN} ${TEST_BUCKET_NAME} ${AWS_REGION}' \
  < manifests/rolesanywhere-test.yaml | kubectl --kubeconfig kubeconfig apply -f -
```

The restricted `envsubst '...'` form (an explicit list of names, not a bare
`envsubst`) matters here for the same reason it does in
[vault.md](vault.md#vault-agent-injector-real-sidecar-real-credential_process-rotation):
both manifests embed real shell scripts (the initContainer's
`credential_process` config, the CA issuer's base64 blobs) alongside the
apply-time placeholders, and an unrestricted `envsubst` would happily
"substitute" any other `$name`-shaped token it finds in those scripts too,
using whatever (usually empty) value that name happens to have in your
shell - silently corrupting the script rather than erroring.

## Manual verification

1. Confirm the cert-manager `Certificate` actually issued (a `False`
   `Ready` condition here means the `ClusterIssuer` from the step above
   isn't in place yet, or the CA Secret's `tls.crt`/`tls.key` don't match):

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
first). Either way, `aws_signing_helper` re-reads the certificate/key files
fresh on every invocation - it isn't a daemon caching them in memory - so
the very next time the AWS CLI's cached STS credentials near their own
(900s) expiry and re-invokes `credential_process`, it signs with the new
certificate automatically. No pod restart, no sidecar analogous to the
Vault Agent Injector needed - confirm by re-running `aws sts get-caller-identity`
a few minutes after forcing the renewal and checking the response still
succeeds (the underlying certificate changed even though nothing in the pod
did).

## Not yet done

- **Real per-pod automation.** Every workload here still needs a
  hand-written `Certificate` resource (see the worked example above) - there's
  no controller minting one automatically from ServiceAccount identity.
  [`csi-driver-spiffe`](https://cert-manager.io/docs/usage/csi-driver-spiffe/)
  (part of the cert-manager project) is the closest real equivalent: a CSI
  driver that mounts a SPIFFE-identity certificate into any pod via a
  volume claim, deriving the identity from the pod's own
  namespace/ServiceAccount, no per-workload YAML at all. Adopting it would
  also mean switching to the literal `spiffe://` scheme (its identities
  *are* real SPIFFE SVIDs), plus running `trust-manager` for trust bundle
  distribution - more infrastructure than this evaluation's single test
  workload currently justifies.
- **ACM Private CA**, as the paid alternative to the self-signed root here,
  for anyone who eventually needs a trust chain that isn't self-signed
  (e.g. because something outside this cluster also needs to trust it).
