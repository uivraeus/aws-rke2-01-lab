#!/usr/bin/env bash
# Runs a command with a temporary SSM port-forward tunnel open in the background,
# closing the tunnel afterward regardless of the command's exit status. Used by the
# Makefile's *-vault targets so they're one-shot (no second shell needed to hold
# `make tunnel-k8s`/`make tunnel-vault` open) - the manual verification steps in
# docs/irsa.md and docs/vault.md still use those long-lived targets directly, since
# those are meant to stay open across several manual commands.
#
# Usage: with-tunnel.sh <ssm-tunnel-command> <local-port> -- <command...>

set -euo pipefail

# Job control (off by default in non-interactive scripts) is what makes the
# backgrounded tunnel below get its own process group instead of sharing this
# script's - required for the cleanup trap to actually work (see next comment).
set -m

tunnel_cmd="$1"; shift
local_port="$1"; shift
if [ "${1:-}" != "--" ]; then
  echo "usage: with-tunnel.sh <ssm-tunnel-command> <local-port> -- <command...>" >&2
  exit 2
fi
shift

eval "$tunnel_cmd" &
tunnel_pid=$!
# `aws ssm start-session` spawns session-manager-plugin as a child process, which is
# what actually holds the local port open - killing just $tunnel_pid (the aws wrapper)
# does not cascade to it, leaking an orphaned tunnel on every single invocation
# (confirmed live: exited 0, tunnel still running). Killing the whole process group
# (the -"$tunnel_pid" form, only meaningful because of `set -m` above) takes both out
# in one shot.
trap 'kill -- "-$tunnel_pid" 2>/dev/null || true; wait "$tunnel_pid" 2>/dev/null || true' EXIT

echo "Waiting for tunnel on localhost:$local_port..." >&2
for _ in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/localhost/$local_port") 2>/dev/null; then
    exec 3>&-
    break
  fi
  sleep 1
done

"$@"
