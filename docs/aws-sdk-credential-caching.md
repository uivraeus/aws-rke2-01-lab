# Why plain file injection can't rotate: AWS SDK/CLI credential-file caching

This traces the assumption behind the README's "Vault Agent Injector" section
([`credential_process` rotation](../README.md#vault-agent-injector-real-sidecar-real-credential_process-rotation)):
that pointing an app straight at a Vault-Agent-rendered `AWS_SHARED_CREDENTIALS_FILE`
(no `credential_process`) can't rotate credentials into a running process, because
"AWS SDKs cache the file for the client's lifetime and never notice it changed."
That claim held up under research - with one nuance worth being precise about.

## The research

Every mainstream AWS SDK resolves static file credentials **once per
session/client object** and caches them there for good. None of them poll the
file or watch it for changes on a plain (non-`credential_process`,
non-expiring) credentials file:

- **botocore** (which both boto3 *and* the AWS CLI are built on): credentials
  are read once at `Session`/client creation and never re-read for that
  object's lifetime. Still an open, unimplemented feature request:
  [boto/botocore#704 "Credentials files are only read once and are never
  reread"](https://github.com/boto/botocore/issues/704),
  [boto/botocore#2450 "Allow refreshing credentials from shared credentials
  file if file is modified"](https://github.com/boto/botocore/issues/2450).
- **AWS SDK for Go v2**: static file credentials are wrapped in a
  `aws.CredentialsCache` with `CanExpire = false`. With no `Expiration` field
  to key off of, the cache treats them as permanent and never refetches. The
  matching feature request (`aws-sdk-go-v2#2135`) was closed **NOT_PLANNED**;
  see the SDK team's own discussion in
  [aws-sdk-go-v2#2775](https://github.com/aws/aws-sdk-go-v2/issues/2775).
- **AWS SDK for Java v2** (current major): no automatic reload at all.
  Notably, **v1 used to do this** -
  [`ProfileCredentialsProvider`](https://docs.aws.amazon.com/AWSJavaSDK/latest/javadoc/com/amazonaws/auth/profile/ProfileCredentialsProvider.html)
  checked the profile file's last-modified timestamp and reloaded on change
  (`refreshIntervalNanos`/`refreshForceIntervalNanos`). That behavior was
  dropped in the v1→v2 rewrite without being called out in the migration
  guide, breaking anyone relying on an external daemon rotating the file -
  see [aws-sdk-java-v2#1754](https://github.com/aws/aws-sdk-java-v2/issues/1754).
- **AWS SDK for JavaScript v3**: each client keeps its own credential cache;
  `fromIni` only re-reads the file if you explicitly pass `ignoreCache: true`
  - off by default, so out of the box it's the same story. See
  [aws-sdk-js-v3#3396](https://github.com/aws/aws-sdk-js-v3/issues/3396).

Background on the mechanism these all lack:
[`credential_process` - AWS SDKs and Tools](https://docs.aws.amazon.com/sdkref/latest/guide/setting-global-credential_process.html)
documents the `Expiration` field as exactly what makes a credential provider
consider re-invoking its source before the SDK actually needs it.

## The nuance: it's per-process, not "the SDK never notices"

The caching lives on the **session/client object**, which lives exactly as
long as the process that created it. A tool that starts a fresh process every
time it runs - like the `aws` CLI - creates a brand-new botocore session per
invocation, so it *does* pick up a rotated file on its very next call. What
actually goes stale is a **long-lived in-process client**: an app that calls
`boto3.Session()` (or the Go/Java/JS equivalent) once at startup and reuses
that object for the rest of the process's life - which is exactly the shape
of a real service pod.

This matters for how this repo's other tests are structured: rotation gets
proven elsewhere in the README via repeated `kubectl exec ... -- aws s3 ls
...` calls, and each of those is a fresh CLI process. Run that same style of
check against a naively-injected file (no `credential_process`) and it would
*appear* to rotate correctly, purely because the CLI re-reads on every
invocation - masking the real failure mode, which only shows up in a
persistent client held open across a rotation.

## Live proof: three long-running readers, one rotated file

[`manifests/vault-agent-config-raw.yaml`](../manifests/vault-agent-config-raw.yaml)
reuses the same `vault-test` Kubernetes auth role and `aws/creds/vault-test`
AWS secrets engine role as the existing injector setup, but renders a plain
INI `AWS_SHARED_CREDENTIALS_FILE` with no `Expiration` field and no
`credential_process` layer - the literal naive path this whole evaluation
moved away from.

[`manifests/vault-test-rotation-proof.yaml`](../manifests/vault-test-rotation-proof.yaml)
points three containers at that same file and polls every 30s, logging a
timestamp plus the last few characters of whichever `AccessKeyId` each reader
currently believes is current:

- **`aws-cli`** - re-invokes the `aws` CLI (a fresh process) each iteration.
- **`python-boto3`** - creates one `boto3.Session()` at startup and reuses it
  for every iteration.
- **`go-sdk`** - creates one `aws-sdk-go-v2` `Config`/`sts.Client` at startup
  (via `go run`, compiled in-cluster inside the `golang` image - no local Go
  toolchain and no custom image/registry needed) and reuses it for every
  iteration.

Expected result, based on the research above: after Vault Agent re-renders
the file with a new lease's `AccessKeyId` (wait out
`terraform-vault`'s `default_sts_ttl`, same as the `credential_process` proof
in the README - forced revocation doesn't trigger an early re-fetch for
non-renewable `assumed_role` credentials, confirmed in the README's
"Proving rotation" note), `aws-cli`'s logged key should change on its next
line while `python-boto3` and `go-sdk` keep logging the pre-rotation key
until the pod is restarted. **Confirmed live - see "Results" below, which
turned out even more decisive than "stale": the long-lived clients don't
just log an old key, they start hard-failing every call.**

### Running it

Prerequisite: `vault-test` namespace/`ServiceAccount`/Vault role already
exist (applied via `manifests/vault-test.yaml` or
`manifests/vault-test-injector.yaml`), and the injector is installed
(`make injector-vault`).

```sh
export VAULT_PRIVATE_IP=$(terraform -chdir=terraform output -raw vault_private_ip)
envsubst '${VAULT_PRIVATE_IP}' < manifests/vault-agent-config-raw.yaml \
  | kubectl --kubeconfig kubeconfig apply -f -
export AWS_REGION=$(terraform -chdir=terraform output -raw aws_region)
envsubst '${AWS_REGION}' < manifests/vault-test-rotation-proof.yaml \
  | kubectl --kubeconfig kubeconfig apply -f -
```

Then tail all three containers at once and watch across a rotation:

```sh
kubectl --kubeconfig kubeconfig -n vault-test logs -f vault-test-rotation-proof \
  --all-containers --prefix
```

### Results (confirmed live, 2026-08-26)

Two rotation events showed up in one run, both confirming the same pattern:

**Pod-startup double-render** (not the main event, but visible immediately):
the `vault-agent-init` container logs in and renders the file once
(`exit_after_auth = true`); the long-running `vault-agent` sidecar then does
its *own* independent login/render on startup (`exit_after_auth = false`) -
a second, distinct `aws/creds/vault-test` lease, before it ever settles into
lease-renewal mode. `python-boto3` (which started fastest, right after `pip
install`) caught the init container's render and stayed on it even after the
sidecar overwrote the file seconds later - already demonstrably stale before
any TTL-driven rotation happened at all.

**Real TTL-driven rotation** (the actual point of this test): the sidecar's
lease, minted around `18:46:10Z`, expired ~900s later. Vault Agent
re-rendered `/vault/secrets/credentials` with a brand-new `AccessKeyId`
(`...Z4WI`, previously `...4FKU`). From that point on:

- **`aws-cli`** - picked up the new key on its very next loop iteration
  (`19:00:28Z`), kept returning a valid `Arn` every 30s after.
- **`python-boto3`** - kept using the old, now-expired credentials from its
  one `Session()` created at startup. Every call has failed with
  `ExpiredToken: The security token included in the request is expired`
  since `19:01:18Z`, and would keep failing indefinitely without a restart.
- **`go-sdk`** - identical outcome: the one `aws-sdk-go-v2` `Config`/`Client`
  created at startup kept retrieving the same cached (now-expired)
  `AccessKeyId` and failing every `GetCallerIdentity` call with
  `ExpiredToken` from `19:01:09Z` onward.

So the real-world failure mode isn't "the SDK silently uses a slightly old
key" - it's a hard, permanent `ExpiredToken` outage for any long-lived
client held open across a lease boundary, while a fresh-process CLI
invocation sails through the same rotation untouched. This is exactly why
`credential_process` (which gives the SDK an `Expiration` it can act on
proactively) is the real fix, not just a nice-to-have.

### A note on the Go container's dependencies

The `go-sdk` container runs `go mod tidy` against `aws-sdk-go-v2`'s `config`
and `sts` packages on startup, which fetches modules from the default Go
module proxy (`proxy.golang.org`) over HTTPS - a module fetch, not a
container/OCI registry push, so it doesn't need any registry credentials or
external image hosting. It does need outbound HTTPS egress from the pod,
same as the `apk add jq` step in `manifests/vault-test.yaml`'s init
container already requires.
