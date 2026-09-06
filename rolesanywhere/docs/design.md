# AWS Roles Anywhere

Part of this repo's exploration of bridging RKE2 workload identity into AWS IAM/STS — see the [main README](../../README.md) for cluster prerequisites and bootstrap steps.

A third, independent path for pods to get scoped AWS credentials, evaluated alongside IRSA and Vault. Roles Anywhere is fundamentally different from both: it authenticates callers via **X.509 client certificates** presented against a registered CA ("Trust Anchor"), not a Kubernetes-native token - IRSA uses the cluster's own OIDC-issued ServiceAccount token, Vault uses that same token via its Kubernetes auth method, but pods have no built-in X.509 identity at all. **[cert-manager](https://cert-manager.io/)** is the bridge here: it issues short-lived, per-workload leaf certificates from a self-signed root CA that Terraform also registers directly with AWS as the Roles Anywhere Trust Anchor.

Unlike IRSA or EKS Pod Identity, AWS has never published an official "Roles Anywhere for Kubernetes" integration - there's no equivalent of `amazon-eks-pod-identity-webhook` for this path. So there's no single "the way AWS intends this to work" to defer to for the Kubernetes-specific parts (issuing/mapping per-pod certificates). The convention below is chosen deliberately rather than copied from a spec.

**Entirely opt-in and off by default** - everything in [`terraform/rolesanywhere.tf`](../../terraform/rolesanywhere.tf) is gated behind `enable_rolesanywhere` (default `false`), independent of `enable_vault`. Set `enable_rolesanywhere = true` in `terraform.tfvars` (or `-var enable_rolesanywhere=true`) before bootstrapping - see [terraform.tfvars.example](../../terraform/terraform.tfvars.example).

What gets provisioned when `enable_rolesanywhere = true`:

- **Self-signed root CA** (`tls_private_key`/`tls_self_signed_cert`, no outputs of their own beyond the two below) - free, unlike AWS Private CA (~$400/month minimum charge, wildly disproportionate for a throwaway lab). Its cert (`rolesanywhere_ca_cert_pem` output) and key (`rolesanywhere_ca_key_pem` output, sensitive) both get loaded into cert-manager separately - see "Bootstrap sequence" below.
- **Roles Anywhere trust anchor** (`rolesanywhere_trust_anchor_arn` output)
  - registers that CA's certificate with AWS as a `CERTIFICATE_BUNDLE` source.
- **Roles Anywhere profile** (`rolesanywhere_profile_arn` output) - the set of role(s) a session against this trust anchor may assume, with `duration_seconds` (`rolesanywhere_sts_duration_seconds` var, default `900`, AWS's own floor) kept short.
- **Roles Anywhere test role** (`rolesanywhere_role_arn` output) - trusts `rolesanywhere.amazonaws.com` via `sts:AssumeRole` + `sts:TagSession` + `sts:SetSourceIdentity`, scoped to sessions from this trust anchor whose certificate carries one specific `workload-id://` URI SAN (see below), with access to only the test bucket below. `sts:SetSourceIdentity` isn't optional in practice, despite reading like it might only matter if you care about source identity - Roles Anywhere always sets one (from the certificate's Subject CN), so a trust policy missing this action fails every `AssumeRole` with a generic `AccessDeniedException: Unable to assume role for <arn>` (confirmed live - it gives no hint that source identity is the missing piece, and the error is identical to what a wrong/missing `PrincipalTag` condition produces).
- **Test bucket** (`rolesanywhere_test_bucket_name` output) - private bucket used purely to prove the Roles Anywhere chain works end to end.

## The `workload-id://` convention

Each Roles Anywhere IAM role needs a trust-policy condition that scopes it to exactly one certificate identity - the same job IRSA's `sub`-claim condition does in [`irsa.tf`](../../terraform/irsa.tf). Roles Anywhere can populate a session's principal tags from the presented certificate's Subject/SAN fields once `sts:TagSession` is granted, so any of those fields can be used as the condition variable (`aws:PrincipalTag/x509Subject/CN`, `.../x509Subject/O`, `.../x509SAN/URI`, ...) - there's no single required field, which is exactly why this needed a deliberate choice.

> **Tag mapping is not automatic**
>
> Despite AWS's own docs describing default rules that include `x509SAN`'s `URI` specifier it is not there. A freshly created `aws_rolesanywhere_profile` returns `attributeMappings: null` from `GetProfile`, and `AssumeRole` fails for every request until the mapping is set explicitly.
>
> The `hashicorp/aws` provider's `aws_rolesanywhere_profile` resource has no argument for attribute mapping. It's a known gap, with a filed issue [#48211](https://github.com/hashicorp/terraform-provider-aws/issues/48211) and a corresponding pending implementation [PR #48493](https://github.com/hashicorp/terraform-provider-aws/pull/48493). Until that ships, this repo works around it with a `terraform_data` + `local-exec` resource right after `aws_rolesanywhere_profile` in [`rolesanywhere.tf`](../../terraform/rolesanywhere.tf).

This repo uses a **URI Subject Alternative Name**, shaped like a SPIFFE ID but under a custom scheme:

```
workload-id://<cluster_name>.internal/ns/<namespace>/sa/<service-account>
```

and each role's trust policy conditions on `aws:PrincipalTag/x509SAN/URI` matching that exact string (see `local.rolesanywhere_test_workload_uri` in [`rolesanywhere.tf`](../../terraform/rolesanywhere.tf)).

Why this shape specifically:

- **Why a URI SAN, not the CN.** The real [SPIFFE](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/) X.509-SVID profile deliberately keeps identity out of the Common Name and carries it as a URI SAN instead - CN is meant for a simple human-readable name, not a structured, parseable identifier. Following that structure (trust-domain + namespace + service-account, as path segments) gives a clean, general shape without inventing a new one, and leaves the CN free for something human-readable later if needed.
- **Why not the literal `spiffe://` scheme.** A real SPIFFE deployment implies a whole stack this repo doesn't have: a Workload API, SPIRE (or equivalent) issuing and attesting identities, trust bundle federation, and enforcement of the full X.509-SVID certificate profile. What's actually here is just a cert-manager `Certificate` with one URI SAN, manually requested - using `spiffe://` would claim compliance this setup doesn't have. `workload-id://` keeps the structure without the claim.
- **Why one compound URI instead of splitting namespace/SA across separate Subject fields (e.g. `O`=namespace, `CN`=service account).** That split is more idiomatic X.509 and was seriously considered - it would let a role condition on `O` alone for "anything in this namespace" - but the URI form composes more naturally with how Kubernetes itself names things (`/ns/<namespace>/sa/<name>` mirrors the API path shape) and matches the direction the wider ecosystem (SPIFFE/SPIRE, [`csi-driver-spiffe`](https://cert-manager.io/docs/usage/csi-driver-spiffe/)) has actually converged on, for anyone comparing this evaluation against real-world practice.

The "ID certificates" can be created via cert-manager's `Certificate` CRD and this is demonstrated in [`rolesanywhere-test.yaml`](../manifests/validation/rolesanywhere-test.yaml). But as described below, there is a better option that leverages automation triggered by annotations.

### Example - adding a second workload/role
To show this generalizes the same way IRSA's `sub`-claim scoping does: say a `billing` namespace needs its own `reports` ServiceAccount to get its own, differently-scoped role.

1. No change to the CA, trust anchor, `ClusterIssuer`, or any of the Kyverno policies - all are already shared across every namespace.
2. Add a new `aws_iam_role` + trust policy in Terraform, identical in shape to `rolesanywhere_test`'s but with `aws:PrincipalTag/x509SAN/URI` = `workload-id://<cluster_name>.internal/ns/billing/sa/reports`, and whatever permissions that role actually needs. Add that role's ARN to the Roles Anywhere profile's `role_arns` (or give it its own profile, if session policies/durations should differ).
3. Add the `reports` `ServiceAccount` in the `billing` namespace with two annotations - `rke2-lab.internal/rolesanywhere-enabled: "true"` and `rke2-lab.internal/rolesanywhere-role-arn: <the new role's ARN>` - and nothing else.

Kyverno (`GeneratingPolicy`) will react on the annotations and auto-generate a `Certificate` CR with `workload-id://<cluster_name>.internal/ns/billing/sa/reports`, derived from the `ServiceAccount`'s own namespace/name. The `Pod`-level wiring is also handled automatically (`MutatingPolicy`) wihtout any additional editing or annotations. See below for more details on this.

So, nothing about the CA/cert-manager/Kyverno wiring changes as workloads are added - only a new `aws_iam_role` and a `ServiceAccount` carrying two annotations, one pair per workload identity.


## Automation and a misconfiguration guard (Kyverno)

As mentioned above, automation triggered by annotation is realized with [Kyverno](https://kyverno.io/) (CNCF Graduated as of March 2026). The automation target two potential problems

- Hand-writing each `Certificate` is cumbersome and there is also a risk of drift when names change.
- Accidental misconfiguration as nothing stops a `Certificate` in namespace A from requesting a URI SAN claiming namespace B's identity - cert-manager signs whatever `spec.uris` says, with no notion that it should match the requesting namespace. (There are options for preventing automatic approvals in cert-manager but that route is not explored here)

[`rolesanywhere/manifests/infra/kyverno-rolesanywhere-policies.yaml`](../manifests/infra/kyverno-rolesanywhere-policies.yaml) has two policies:

- **`GeneratingPolicy`** - watches `ServiceAccount`s for the `rke2-lab.internal/rolesanywhere-enabled: "true"` annotation (reusing this repo's existing custom annotation prefix from the IRSA pod-identity-webhook, see [irsa/docs/design.md](../../irsa/docs/design.md)) and generates a matching `Certificate` automatically, deriving the `workload-id://` URI from the ServiceAccount's own namespace/name via [`rolesanywhere/manifests/infra/kyverno-config.yaml`](../manifests/infra/kyverno-config.yaml)'s `cluster-config` `ConfigMap` (a `GeneratingPolicy`'s CEL has no way to read a Terraform output directly, so the cluster name is bridged across the same way `local_file.ansible_terraform_vars` already bridges other Terraform values into Ansible). `rolesanywhere-test.yaml`'s `Certificate` block is gone as of this policy - only the `ServiceAccount`'s annotation remains.
- **`ValidatingPolicy`** - rejects any `Certificate` targeting the `rolesanywhere-ca` `ClusterIssuer` whose `spec.uris` doesn't match its own namespace. Deliberately scoped to that one `ClusterIssuer` specifically (via a `matchConditions` check on `spec.issuerRef.name`), so it can't interfere with `pod-identity-webhook`'s own (or other), unrelated self-signed cert-manager `Certificate` ([irsa/docs/design.md](../../irsa/docs/design.md)).

This automation targets _accidental_ misconfiguration - typos, a copy-pasted `Certificate` with the wrong namespace left in. It is _**not**_ a defense against a deliberate, already-RBAC-authorized attempt to bypass it. Anyone with enough RBAC permissions could disable the `ValidatingPolicy` outright, or delete/recreate a `Secret` across namespaces regardless of what minted it in the first place.

**Current, not deprecated, Kyverno API**: both policies use the CEL-based `policies.kyverno.io/v1` `GeneratingPolicy`/`ValidatingPolicy` CRDs, not the older `ClusterPolicy` generate/validate rule style - `ClusterPolicy` was deprecated in Kyverno 1.17 (Feb 2026), with removal planned for 1.20 (Oct 2026). Kyverno's own Helm install output confirms this independently, unprompted: *"The legacy kyverno.io policy types are deprecated and will be removed in a future release. Migrate to their policies.kyverno.io replacements..."*.

### Pod-level wiring (Kyverno `MutatingPolicy`)

The `GeneratingPolicy`/`ValidatingPolicy` above only ever reach the `Certificate`. Without additional automation the actual pod-level wiring (the `fetch-signing-helper` initContainer, the `signing-helper`/`aws-config` `emptyDir` volumes, the `rolesanywhere-tls` `Secret` mount, `AWS_CONFIG_FILE`/`AWS_REGION`) would still have to be hand-written in every `Pod` spec, exactly like in `rolesanywhere-test.yaml`.

[`rolesanywhere/manifests/infra/kyverno-rolesanywhere-mutation.yaml`](../manifests/infra/kyverno-rolesanywhere-mutation.yaml) closes that gap with a `MutatingPolicy` - the same role `amazon-eks-pod-identity-webhook` plays for IRSA, but expressed as a Kyverno CEL policy instead of a bespoke Go webhook. [`rolesanywhere/manifests/validation/rolesanywhere-mutation-test.yaml`](../manifests/validation/rolesanywhere-mutation-test.yaml) is the fully-automated counterpart to `rolesanywhere-test.yaml` - mutually exclusive, identically-named objects, just two `ServiceAccount` annotations and a bare `Pod`.

### URI-SAN-only gotcha

Roles Anywhere does not accept certificates with an empty Subject, even though [RFC 5280](https://datatracker.ietf.org/doc/html/rfc5280) explicitly permits one when the SAN extension is present and marked critical, and cert-manager happily issues exactly that (an empty Subject is what you get from a `Certificate` with no `commonName`/`subject` set, which is what a URI-SAN-only identity naturally looks like). AWS's own docs say so plainly - ["Certificates with empty subjects are NOT yet supported"](https://docs.aws.amazon.com/rolesanywhere/latest/userguide/trust-model.html) - and every `AssumeRole` fails with the same generic `AccessDeniedException`, even against a fully unconditioned trust policy. Every `Certificate` in this repo therefore sets a `commonName` purely to satisfy that constraint - see `rolesanywhere-test.yaml`'s comment on the field. It plays no role in authorization here; the URI SAN remains the only thing any trust policy condition actually matches on.

## Bootstrap sequence

Set `enable_rolesanywhere = true` in `terraform.tfvars` first, then:

```sh
make bootstrap-k8s      # if not already done

make tunnel-k8s         # in its own shell, leave it running - the Helm installs below need
                        # `kubectl`/`helm --kubeconfig kubeconfig` to reach the cluster,
                        # which (per the main README) means localhost:6443 tunneled to the
                        # control node, not the internet
make cert-manager       # if not already installed (also needed for irsa/docs/design.md's webhook)

make kyverno            # if not already installed
```

`make bootstrap-k8s` (`apply-k8s` + `ansible-k8s`) already runs `terraform apply` against this same `terraform/` root as its first step, so it alone provisions the CA/trust anchor/profile/test role and registers the `x509SAN`/`URI` attribute mapping (the `terraform_data` workaround - see "The `workload-id://` convention" above) - no separate `terraform apply` needed. If the base cluster is already bootstrapped and you're only now flipping `enable_rolesanywhere` on, run `cd terraform && terraform apply` by itself instead of the full `make bootstrap-k8s` - it picks up the newly-gated resources without re-running Ansible/RKE2 install for no reason.

Then load the CA into cert-manager, wire up the Kyverno policies, and apply the test workload (open `make tunnel-k8s` in another shell first):

```sh
export ROLESANYWHERE_CA_CERT_B64=$(terraform -chdir=terraform output -raw rolesanywhere_ca_cert_pem | base64 -w0)
export ROLESANYWHERE_CA_KEY_B64=$(terraform -chdir=terraform output -raw rolesanywhere_ca_key_pem | base64 -w0)
envsubst '${ROLESANYWHERE_CA_CERT_B64} ${ROLESANYWHERE_CA_KEY_B64}' \
  < rolesanywhere/manifests/infra/rolesanywhere-ca-issuer.yaml | kubectl --kubeconfig kubeconfig apply -f -
```

```sh
export CLUSTER_NAME=$(terraform -chdir=terraform output -raw cluster_name)
export ROLESANYWHERE_TRUST_ANCHOR_ARN=$(terraform -chdir=terraform output -raw rolesanywhere_trust_anchor_arn)
export ROLESANYWHERE_PROFILE_ARN=$(terraform -chdir=terraform output -raw rolesanywhere_profile_arn)
export AWS_REGION=$(terraform -chdir=terraform output -raw aws_region)
envsubst '${CLUSTER_NAME} ${ROLESANYWHERE_TRUST_ANCHOR_ARN} ${ROLESANYWHERE_PROFILE_ARN} ${AWS_REGION}' \
  < rolesanywhere/manifests/infra/kyverno-config.yaml | kubectl --kubeconfig kubeconfig apply -f -
kubectl --kubeconfig kubeconfig apply -f rolesanywhere/manifests/infra/kyverno-rolesanywhere-policies.yaml
kubectl --kubeconfig kubeconfig apply -f rolesanywhere/manifests/infra/kyverno-rolesanywhere-mutation.yaml
kubectl --kubeconfig kubeconfig get generatingpolicy,validatingpolicy,mutatingpolicy   # all three should show a ready/valid status
```

```sh
export ROLESANYWHERE_ROLE_ARN=$(terraform -chdir=terraform output -raw rolesanywhere_role_arn)
export TEST_BUCKET_NAME=$(terraform -chdir=terraform output -raw rolesanywhere_test_bucket_name)
```

Either the hand-wired Pod (all wiring explicit, useful as a reference for what the MutatingPolicy is actually doing on your behalf):

```sh
envsubst '${ROLESANYWHERE_TRUST_ANCHOR_ARN} ${ROLESANYWHERE_PROFILE_ARN} ${ROLESANYWHERE_ROLE_ARN} ${TEST_BUCKET_NAME} ${AWS_REGION}' \
  < rolesanywhere/manifests/validation/rolesanywhere-test.yaml | kubectl --kubeconfig kubeconfig apply -f -
```

...or the fully-automated one (mutually exclusive with the above - `kubectl delete namespace rolesanywhere-test` first if switching):

```sh
envsubst '${ROLESANYWHERE_ROLE_ARN} ${TEST_BUCKET_NAME}' \
  < rolesanywhere/manifests/validation/rolesanywhere-mutation-test.yaml | kubectl --kubeconfig kubeconfig apply -f -
kubectl --kubeconfig kubeconfig -n rolesanywhere-test get certificate rolesanywhere-test   # generated automatically - see below
```

With the `GeneratingPolicy`'s RBAC correctly in place, the `Certificate` above typically appears within a second or two of the `ServiceAccount`, so the `Pod` should reach `Running` on its own without any extra steps.

The restricted `envsubst '...'` form (an explicit list of names, not a bare `envsubst`) matters here for the same reason it does in [vault/docs/design.md](../../vault/docs/design.md#vault-agent-injector-real-sidecar-real-credential_process-rotation): both manifests embed real shell scripts (the initContainer's `credential_process` config, the CA issuer's base64 blobs) alongside the apply-time placeholders, and an unrestricted `envsubst` would happily "substitute" any other `$name`-shaped token it finds in those scripts too, using whatever (usually empty) value that name happens to have in your shell - silently corrupting the script rather than erroring.

## Manual verification

1. Confirm the `Certificate` was actually generated (by the `GeneratingPolicy`, from the `ServiceAccount`'s annotation - there's no `Certificate` in `rolesanywhere-test.yaml` itself to apply) and issued. Missing entirely means the `GeneratingPolicy` didn't fire - check its own status and the `ServiceAccount`'s annotation first; present but `Ready: False` means the `ClusterIssuer` from the step above isn't in place yet, or the CA Secret's `tls.crt`/`tls.key` don't match:

   ```sh
   kubectl --kubeconfig kubeconfig -n rolesanywhere-test get certificate rolesanywhere-test
   ```

2. Confirm the pod actually assumed the role via Roles Anywhere:

   ```sh
   kubectl --kubeconfig kubeconfig exec -n rolesanywhere-test -it rolesanywhere-test -- aws sts get-caller-identity
   ```

   The `Arn` in the response should be `arn:aws:sts::<account_id>:assumed-role/<rolesanywhere_role_arn's role name>/...`.

3. Confirm the IAM policy scoping by hitting the test bucket - same expand-inside-the-container caveat as the IRSA/Vault docs (an unset local variable silently turns `s3://$TEST_BUCKET_NAME/` into `s3://`, which calls the very different `s3:ListAllMyBuckets` action):

   ```sh
   kubectl --kubeconfig kubeconfig exec -n rolesanywhere-test -it rolesanywhere-test -- sh -c 'aws s3 ls s3://$TEST_BUCKET_NAME/'
   kubectl --kubeconfig kubeconfig exec -n rolesanywhere-test -it rolesanywhere-test -- sh -c \
     'echo hello > /tmp/f && aws s3 cp /tmp/f s3://$TEST_BUCKET_NAME/f && aws s3 ls s3://$TEST_BUCKET_NAME/'
   ```

4. Confirm scoping the other way too - this role should get `AccessDenied` against the IRSA/Vault test buckets, proving it's actually scoped and not accidentally broad:

   ```sh
   IRSA_TEST_BUCKET=$(terraform -chdir=terraform output -raw irsa_test_bucket_name)
   kubectl --kubeconfig kubeconfig exec -n rolesanywhere-test -it rolesanywhere-test -- sh -c \
     "aws s3 ls s3://$IRSA_TEST_BUCKET/"
   ```

Success on steps 2-4 confirms the full chain: cert-manager issues a leaf cert with the expected `workload-id://` URI SAN from the shared root CA -> Roles Anywhere validates it against the trust anchor and tags the session with that URI -> the IAM role's trust policy condition matches -> the pod ends up with exactly the intended S3 access, nothing more.

## Proving rotation

cert-manager's own floor (`duration` >= 1h, `renewBefore` >= 5m) means the `Certificate` above only renews naturally once an hour - a real constraint, not a deliberately short window the way Vault's 900s STS TTL is. Rather than waiting out the hour, force a renewal on demand:

```sh
kubectl --kubeconfig kubeconfig -n rolesanywhere-test delete secret rolesanywhere-test-tls
```

cert-manager notices the Secret is gone and reissues immediately (or use [`cmctl renew rolesanywhere-test -n rolesanywhere-test`](https://cert-manager.io/docs/reference/cmctl/#renew) if `cmctl` is installed, which renews in place without deleting the Secret first). `aws_signing_helper` itself re-reads the certificate/key files fresh on every invocation - it isn't a daemon caching them in memory - so the very next `credential_process` invocation signs with the new certificate automatically. No pod restart, no sidecar analogous to the Vault Agent Injector needed.

**Confirming this without waiting out the full session duration is trickier than it sounds** (confirmed live): simply re-running `aws sts get-caller-identity` right after forcing the renewal still shows the *old* certificate's identity, because the AWS CLI caches the credentials `credential_process` returned and won't re-invoke it until they're close to expiring - this is expected CLI behavior, not a sign rotation didn't work. The session name in `GetCallerIdentity`'s response is always the hex-encoded serial number of whichever certificate authenticated it (a Roles Anywhere convention), so the most direct proof is to bypass the CLI's cache and invoke the helper directly, twice - once before, once after forcing renewal:

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

Compare the certificate's own serial (`openssl x509 -noout -serial -in <(kubectl ... get secret rolesanywhere-test-tls -o jsonpath=... | base64 -d)`) against the session name in a fresh `aws sts get-caller-identity` run using those exact credentials - they match after rotation, proving the helper picked up the new certificate, independent of whatever the CLI's own cache is still holding onto.

## Not yet done

- **The `MutatingPolicy`'s "invariant to existing containers/volumes" claim is reasoned from the mechanism, not fully live-tested.** Every mutation (`initContainers`/`volumes` via list concatenation, `volumeMounts`/`env` via one `indexOf()`-addressed `JSONPatch` per container) is count-invariant by construction - nothing hardcodes "exactly one container" or "no pre-existing volumes" - and Kubernetes itself would reject a genuine container/volume *name* collision loudly rather than silently corrupting anything. What's actually been run live is N=1 in every dimension (one container, zero pre-existing init containers/volumes). One confirmed, different-in-kind exception: `AWS_CONFIG_FILE`/`AWS_REGION` are env var *names*, not object names, and Kubernetes does not enforce uniqueness on those - an app already setting either would not be rejected, it would silently end up with two entries of that name, with the injected one (appended last) winning at runtime. Worth an actual multi-container, pre-existing-volume live test before trusting the invariance claim fully.
- **`fetch-signing-helper` downloads `aws_signing_helper` from `rolesanywhere.amazonaws.com` at every single pod start** - fine for a lab, a real weak point anywhere with restricted egress or supply-chain concerns: every pod creation reaches out over the network and trusts that URL to keep serving the exact same binary. The official docker image doesn't hold a statically linked binary so it is not possible to just OCI-volume-mount it into the application container's filesyste. But it is probably not a big deal building a custom image that enables this.
  - **A more structural option the same image unlocks**: run `aws_signing_helper serve` (a long-running local IMDSv2-compatible endpoint on `127.0.0.1:9911`, the same discovery mechanism real EC2 instance-profile credentials use) as a sidecar instead of an initContainer. That would remove the `signing-helper`/`aws-config` shared volumes and the `credential_process` config file entirely - the app container would need at most one env var (`AWS_EC2_METADATA_SERVICE_ENDPOINT`), possibly none if its SDK already checks IMDS by default. Deliberately **not** the same tradeoff this repo's own Vault Agent Injector already documents, though it looks similar on the surface: the Injector sidecar exists because Vault's static/one-shot path genuinely *can't* rotate credentials at all - that's its whole reason to exist. Rotation already works here with the current one-shot `initContainer` design (`credential_process` re-invokes the whole helper binary fresh on every SDK credential refresh, re-reading whatever cert cert-manager most recently rotated onto disk. A `serve` sidecar here would trade one continuously-running extra container per pod for removing the shared-volume/config-file plumbing and a cheaper per-refresh cost (a local HTTP GET vs. exec-ing the whole helper binary as a subprocess each time).
- **Certificates live in `Secret`s, readable by anyone with ordinary Secret-read RBAC - unlike this repo's other two paths.** cert-manager always writes the issued key material to a `kubernetes.io/tls` `Secret` object. That's fundamentally different from IRSA's projected ServiceAccount token (minted by kubelet straight into the pod's own ephemeral volume via the TokenRequest API, never persisted to etcd as a Secret at all) or Vault's rendered files (`emptyDir`-only, same story) - both of those need a live exec into the specific pod (or node/kubelet compromise) to extract; a cert-manager `Secret` can be read by anyone with `get`/`list` RBAC on Secrets, from anywhere, at any later time, and copied into a different namespace's pod entirely - `kubectl get secret ... -o yaml | kubectl apply -n other-namespace -f -`. Neither Kyverno policy above touches this: the `ValidatingPolicy` only ever sees `Certificate`/ `CertificateRequest` objects at the moment they're created, not what happens to the `Secret` cert-manager writes afterward. [`csi-driver-spiffe`](https://cert-manager.io/docs/usage/csi-driver-spiffe/) (part of the cert-manager project) closes both this gap and the one above at once: a CSI driver that mounts a SPIFFE-identity certificate straight into a pod's own node-local filesystem via a volume claim - never a Secret object - deriving the identity from the pod's own namespace/ServiceAccount automatically, no per-workload YAML at all. Adopting it would also mean switching to the literal `spiffe://` scheme (its identities *are* real SPIFFE SVIDs), plus running `trust-manager` for trust bundle distribution - more infrastructure than this evaluation's single test workload currently justifies, but the strongest real answer to both open items here.
- **ACM Private CA**, as the paid alternative to the self-signed root here, for anyone who eventually needs a trust chain that isn't self-signed (e.g. because something outside this cluster also needs to trust it).

