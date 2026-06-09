#!/usr/bin/env bash
# qp-nebula sim - exercise the `nebula ctl` control client against a REAL daemon's unix-domain
# control socket on a VM: the deployment tier (real systemd, real socket, the real binary),
# which the toolbox smoke-ctl cannot provide. The sim daemons are configured with
# control.socket (render_cfg), so `/opt/qpn/qp-nebula ctl` talks to the live in-memory state -
# the qp-ssh-free replacement for the retired embedded sshd. A tunnel is brought up first so
# list-hostmap has a peer to report.
set -euo pipefail
LOG_TAG=run
. "$(dirname "$0")/_common.sh"
INV="${1:?usage: test-ctl.sh <inventory.env>}"
FAILED=0
. "$INV"; destroy_nodes; trap on_exit EXIT   # clean slate; teardown on success, keep on failure

topology_up "$INV"
# Bring the tunnel(s) up so list-hostmap has something to show.
tally="$(assert_matrix)" || FAILED=1; log "overlay reachability: $tally"

# Drive ctl over the control socket of the first node.
n="${NODES[0]%%:*}"; a="${MGMT[$n]}"
CTL="$D_BIN ctl -socket $D_SOCK"

# check <desc> <remote-cmd> <grep -E pattern>
check(){
  local desc="$1" cmd="$2" pat="$3" out
  out="$(nssh "$a" "$cmd" 2>/dev/null || true)"
  if printf '%s' "$out" | grep -qE "$pat"; then
    log "  OK: $desc"
  else
    echo "  FAIL: $desc (got: $(printf '%s' "$out" | head -1))" >&2; FAILED=1
  fi
}

log "exercising nebula ctl on $n ($a)"
check "version returns a version"     "$CTL version"      '.'
check "list-hostmap shows a peer"     "$CTL list-hostmap" '[0-9]+\.[0-9]+'
check "help lists the commands"       "$CTL help"         'list-hostmap'
check "unknown command is graceful"   "$CTL bogus"        'did not understand'

# Exit-code propagation: a reachable socket succeeds (0); an unreachable one fails (non-zero).
if nssh "$a" "$CTL version >/dev/null 2>&1"; then
  log "  OK: exit 0 on success"
else
  echo "  FAIL: version exited non-zero" >&2; FAILED=1
fi
if nssh "$a" "$D_BIN ctl -socket /run/nope.sock version >/dev/null 2>&1"; then
  echo "  FAIL: unreachable socket exited 0" >&2; FAILED=1
else
  log "  OK: non-zero exit on an unreachable socket"
fi

[ "$FAILED" = 0 ] && { echo "qp-nebula sim ctl: PASS (real control socket + nebula ctl on a VM)"; exit 0; } \
                  || { echo "qp-nebula sim ctl: FAIL"; exit 1; }
