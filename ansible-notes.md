# Ansible notes

Standalone notes on Ansible behavior that turned out to be non-obvious while working on
this repo (specifically the OIDC mirror-sync tasks in `ansible/roles/rke2_server`).
Not a changelog - just things worth remembering next time this bites.

## `delegate_to` inherits the entire `all` group's variables - including `ansible_become`

**Where this showed up:** `ansible/roles/rke2_server/tasks/main.yml`, the two
`amazon.aws.s3_object` tasks that upload the OIDC discovery doc/JWKS. They run with
`delegate_to: localhost` (the AWS SSO profile that can write to the OIDC bucket only
exists on the operator's machine, not on the remote EC2 node - see "why delegate at
all" below), and explicit `become: false`, since `group_vars/all/vars.yml` sets
`ansible_become: true` globally (needed for the RKE2 install tasks on the actual
remote nodes).

Despite `become: false` at the task level, the delegated task still ran as root. This
broke the S3 upload in a confusing way: running as root meant `$HOME=/root`, so
`boto3` looked for `/root/.aws/config` instead of the operator's real
`~/.aws/config`, and failed with `"The config profile (...) could not be found"` - a
misleading error, since the profile *was* defined, just not where the process was
looking.

### The mechanism

This is not a `become`-specific bug. `delegate_to` targets - including the implicit
`localhost`, and even hosts that aren't in inventory at all - inherit **every**
variable defined on the `all` group, not just connection-related ones. Confirmed with
a minimal repro (dummy inventory host delegating a `debug` task to `localhost`):

```yaml
# group_vars/all.yml
ansible_user: ssm-user
ansible_become: true
my_custom_var: hello-from-all-group
```

```
TASK [show inherited vars for the delegated localhost task] ********************
ok: [dummyhost -> localhost] => {
    "msg": "ansible_user=ssm-user ansible_become=True my_custom_var=hello-from-all-group"
}
```

All three leak through - `ansible_become`, the connection variable `ansible_user`, and
an arbitrary plain variable with no special meaning. This is a general "delegated
hosts inherit everything from `all`" design decision, not a narrow become-only quirk.
`become` just happens to be the variable whose leakage is most consequential, since it
silently changes *who the process runs as*.

### Is this a known bug, or expected behavior?

Both, depending on which layer you look at:

- The original, narrower complaint - `become: no` at the task/host level not
  overriding an inventory host's `ansible_become: yes` for a delegated/`local_action`
  task - **was treated as a bug and fixed**, back in Ansible 2.0 (2016). See
  [ansible/ansible#12577](https://github.com/ansible/ansible/issues/12577), closed by
  maintainer `bcoca` after merging a fix.
- The deeper mechanism - that a `delegate_to` target (including one not in inventory)
  unconditionally inherits the `all` group's variables - was **explicitly reaffirmed
  as intentional, by design**, as recently as November 2023. See
  [ansible/ansible#82191](https://github.com/ansible/ansible/issues/82191): a user
  showed the actual behavior contradicted Ansible's own docs (which said delegated
  hosts *don't* inherit `all`-group vars). Maintainer `s-hertel` traced it to
  `get_vars()` building a temporary host object for the delegate target and
  unconditionally pulling in the `all` group. `bcoca` (the same maintainer from the
  2016 fix) confirmed: *"at one point 'all' did not affect some hosts, but the
  decision was made to change this, all hosts are always affected by 'all' group,
  those specific docs were missed on that change."* The resolution was to fix the
  **documentation** to match the code, not the other way around.
- A decade of adjacent reports sit around this same area - become/delegate/connection
  variable interactions that are each either closed as "working as intended" or as
  narrower edge cases:
  [#69603](https://github.com/ansible/ansible/issues/69603),
  [#71198](https://github.com/ansible/ansible/issues/71198),
  [#70359](https://github.com/ansible/ansible/issues/70359),
  [#79569](https://github.com/ansible/ansible/issues/79569),
  [#77954](https://github.com/ansible/ansible/issues/77954). None of them fully nail
  down "task-level `become: false` always wins for a delegated target" as a hard
  guarantee.

**Bottom line:** treat "a `delegate_to` task inherits all of `group_vars/all`,
`become` included, regardless of task-level overrides" as the safe assumption going
forward, not an occasional glitch.

### The workaround used here

Don't fight `become` resolution for the delegated task. Instead, force the module's
execution environment directly:

```yaml
environment:
  HOME: "{{ lookup('env', 'HOME') }}"
```

Two things make this reliable:

1. `lookup('env', ...)` always evaluates **on the Ansible controller process itself**,
   regardless of which host the surrounding task targets or delegates to - so it
   reads the operator's real `$HOME` even from inside a play targeting a remote host.
2. A task's `environment:` keyword sets environment variables for the module's
   execution process directly, independent of whether `become` silently kicked in.
   Since `boto3`/Python's `os.path.expanduser` honors `$HOME` when set, this makes it
   find the right `~/.aws/config` regardless of which user the process actually ran
   as.

This doesn't fix the underlying `become` inheritance - the task still runs as root,
just with the right `HOME`. Harmless for a boto3 S3 call; would be worth revisiting if
a future delegated task needed something more sensitive than "find the right config
file."

### Why `delegate_to: localhost` was needed here at all

The OIDC mirror-sync task authenticates to AWS using the operator's SSO profile
(`aws_profile`, e.g. `ulf-lab`), which only exists on the machine running
`ansible-playbook`. The remote EC2 control node has no such credentials:

- Its only AWS identity is the EC2 instance role, which deliberately isn't granted
  permission to write to the OIDC bucket (kept minimal on purpose - see
  `terraform/irsa.tf`).
- It has no `~/.aws/config` with an SSO session at all.

So the only place with credentials authorized to write to the OIDC bucket is wherever
Ansible itself is running - hence delegating just the upload step to `localhost`,
while the earlier "fetch the live discovery doc via `kubectl`" step still runs on the
remote control node (only it has the admin kubeconfig and a network path to its own
`kube-apiserver`).
