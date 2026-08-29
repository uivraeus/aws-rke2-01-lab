# Vault Agent template functions: what's actually registered

Deep-dive into which Consul Template functions the Vault Agent Injector
actually has available, for the exact chart/version this repo pins:
`hashicorp/vault` Helm chart `0.34.1`, app version (Vault/Vault Agent)
`2.0.4`. Grew out of the caveat noted in [docs/vault.md](vault.md)'s "Vault Agent
Injector" section, where `manifests/vault-agent-config.yaml` needed a
shell-script workaround because the obvious template-only approach
(`sprig_now`/`sprig_date`/`timeAdd`) errored as undefined against the live
cluster. This documents *why*, precisely, and what else is or isn't
available - traced from source rather than general Consul Template docs,
which have already proven wrong once for this dependency chain.

## The dependency chain (confirmed via raw `go.mod`, not docs)

```
hashicorp/vault v2.0.4
  -> github.com/hashicorp/consul-template v0.41.1
       -> github.com/Masterminds/sprig/v3 v3.3.0
```

Vault Agent embeds `consul-template`'s template engine directly (no
separate binary) - `command/agent/template/template.go` builds a
`consul-template/manager.Runner` from the templates in the Vault Agent
config. The function map it renders with comes straight from
`consul-template`'s own `template/template.go`, unmodified: no Vault- or
chart-specific denylist exists anywhere in the code paths that build Vault
Agent's runtime config
(`command/agent/internal/ctmanager/runner_config.go`,
`command/agent/config/config.go` - both checked directly, zero mentions of
`denylist`/`FunctionDenylist`/`sprig`). Whatever consul-template v0.41.1
registers is exactly what's available here.

## Why `sprig_now` / `sprig_date` / `timeAdd` are undefined

consul-template's `template.go` *does* register every Sprig function under
a `sprig_` prefix by default - but only via
[`sprig.HermeticTxtFuncMap()`](https://github.com/Masterminds/sprig),
not the full `sprig.TxtFuncMap()`. The Hermetic variant deliberately
deletes ~20 "nonhermetic" (non-reproducible / depends on
environment or global state) functions before returning the map:

- **Every date/time function**: `date`, `date_in_zone`, `date_modify`,
  `dateInZone`, `dateModify`, `now`, `htmlDate`, `htmlDateInZone`
- **Random-string functions**: `randAlphaNum`, `randAlpha`, `randAscii`,
  `randNumeric`, `randBytes`, `uuidv4`
- Sprig's own `env`/`expandenv` (irrelevant here - consul-template
  registers its *own* separate `env`/`mustEnv`/`envOrDefault`, unaffected
  by this list, see below)
- `getHostByName`

`sprig_now` and `sprig_date` were never in the map to begin with - not
denied, genuinely absent. That's confirmed by the error text itself:
consul-template has a *separate* glob-based denylist mechanism
(`function_denylist`, e.g. `sprig_*`) that replaces denied functions with
one that errors `"function is disabled"` - a materially different message
from the `"function \"X\" not defined"` actually seen live, which is Go's
own `text/template` parse-time error for a name that's not a map key at
all.

`timeAdd` doesn't exist anywhere in Sprig v3.3.0's source under that name,
hermetic-excluded or otherwise - it's not a Sprig function at all despite
general Consul Template docs describing it as available. Those docs are
simply wrong for this specific dependency graph.

## Confirmed live (2026-08-22, against chart 0.34.1 / Vault Agent 2.0.4)

A single scratch probe pod (`vault.hashicorp.com/agent-inject` +
`agent-configmap`, same mechanism as `manifests/vault-test-injector.yaml`,
deployed into the `vault-test` namespace using its existing `vault-test`
ServiceAccount/Vault role) rendered this template in one `vault-agent-init`
pass, no crash-loop:

```
sprig_upper: {{ sprig_upper "test" }}
env_path: {{ env "PATH" }}
env_default: {{ envOrDefault "NONEXISTENT_VAR_XYZ" "fallback-value" }}
sprig_toDate: {{ sprig_toDate "2006-01-02" "2024-01-01" }}
```

rendered to:

```
sprig_upper: TEST
env_path: /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
env_default: fallback-value
sprig_toDate: 2024-01-01 00:00:00 +0000 UTC
```

Confirms:

- **Non-date/non-random `sprig_*` functions genuinely work** - the
  "Sprig functions aren't registered" framing in [docs/vault.md](vault.md)'s
  original caveat was too broad. String/math/list Sprig helpers (`sprig_upper`,
  `sprig_trunc`, `sprig_add1`, `sprig_list`, etc.) are all registered and
  usable; it's specifically the date/time and random ones that are
  missing, and precisely because of the Hermetic-map exclusion above -
  not a Vault- or chart-level restriction.
- **`env`/`mustEnv`/`envOrDefault` are registered and work as
  documented**, including the default-value fallback. `env`'s
  implementation (`consul-template/template/funcs.go`) checks a
  caller-supplied `[]string` first, then falls back to `os.Getenv` on the
  Vault Agent process's own environment. Vault's `ctmanager.NewConfig()`
  never populates that `[]string` (confirmed by source - zero mentions of
  `env` in `runner_config.go`), so in practice `env`/`envOrDefault` read
  whatever's actually set on the `vault-agent-init`/`vault-agent`
  containers themselves.
- **What that actually exposes**, confirmed via `kubectl exec ... -- env`
  on the sidecar: Kubernetes' auto-injected service-discovery vars
  (`KUBERNETES_SERVICE_HOST`, `KUBERNETES_PORT*`), plus a handful the
  injector itself sets - `NAME`, `NAMESPACE`, `POD_IP`, `HOST_IP`,
  `HOME`, `PATH`, `VAULT_ADDR`, `VAULT_LOG_FORMAT`, `VAULT_LOG_LEVEL`,
  `VAULT_SKIP_VERIFY`. Given the injector annotation reference has no
  mechanism to add custom env vars to these specific containers (checked
  separately, still true), `env`/`envOrDefault` can't be used to pipe in
  arbitrary app-level config - but `env "NAMESPACE"` / `env "NAME"` are
  legitimately useful if a shared ConfigMap template ever needs to be
  namespace- or pod-aware without per-namespace duplication.
- **`sprig_toDate` survives the Hermetic exclusion** (it's pure: takes an
  explicit layout string and an explicit string to parse, no
  environment/global-state fallback, unlike `date`/`dateInZone` which
  silently fall back to `time.Now()` for unrecognized input types - the
  actual reason those two are classified nonhermetic). It renders a valid
  `time.Time`, formatted by Go's default `String()` method, not RFC3339 -
  useful to know, but it does **not** provide a path to replace
  `manifests/vault-agent-config.yaml`'s epoch-to-RFC3339 shell workaround:
  the one function that takes a raw Unix-epoch *integer* input
  (`date`/`dateInZone`) is exactly the one that's excluded. `toDate` needs
  the input pre-formatted as a string matching an explicit calendar
  layout, which an epoch integer isn't. The shell `command` hook in
  `config-init.hcl`/`config.hcl` remains the right approach unless a
  future chart version changes this.

## Reproducing this for a future chart bump

If the chart's app version changes, don't re-guess function names live -
repeat the source chase:

1. `curl -s https://raw.githubusercontent.com/hashicorp/vault/v<version>/go.mod | grep consul-template`
2. `curl -s https://raw.githubusercontent.com/hashicorp/consul-template/v<that-version>/go.mod | grep Masterminds/sprig`
3. Fetch both `consul-template`'s `template/template.go` (the `funcMap`
   function - lists every non-Sprig function directly, and shows whether
   Sprig is merged in unconditionally or behind a denylist) and Sprig's
   `functions.go`/`date.go` (the `nonhermeticFunctions` list) at those
   exact tagged versions.
4. Cross-check against `hashicorp/vault`'s
   `command/agent/internal/ctmanager/runner_config.go` and
   `command/agent/config/config.go` for anything Vault-specific layered
   on top (a default denylist, a different FuncMap entirely, etc.) -
   there wasn't one for 2.0.4, but that's not guaranteed to stay true.

Only fall back to the live crash-loop probe technique (a scratch
`agent-configmap` pod with `{{ funcname args }}` as the entire template
body, checking `vault-agent-init` logs for `"not defined"` vs. real
output) for anything the source doesn't settle outright.
