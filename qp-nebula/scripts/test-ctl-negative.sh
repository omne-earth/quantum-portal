#!/usr/bin/env bash
# qp-nebula sim - negative authz for the control socket. The socket's local gate is filesystem
# perms (0660, owned by the daemon user + the `nebula` group); there is no network listener.
# Prove that an UNPRIVILEGED user (not the owner, not in the socket's group) is REFUSED, while
# the owner (root, the daemon user in the sim) is allowed. This is the deployment-tier check the
# toolbox cannot do - it needs a real socket owned by a real daemon under real uids.
set -euo pipefail
LOG_TAG=run
. "$(dirname "$0")/_common.sh"
INV="${1:?usage: test-ctl-negative.sh <inventory.env>}"
FAILED=0
. "$INV"; destroy_nodes; trap on_exit EXIT

topology_up "$INV"
tally="$(assert_matrix)" || FAILED=1; log "overlay reachability: $tally"

n="${NODES[0]%%:*}"; a="${MGMT[$n]}"
CTL="$D_BIN ctl -socket $D_SOCK"

log "control socket perms on $n:"
nssh "$a" "ls -l $D_SOCK" 2>/dev/null | sed 's/^/    /'

# Positive control: the owner (root, the daemon user) is allowed.
if nssh "$a" "$CTL version >/dev/null 2>&1"; then
  log "  OK: owner (root) is allowed"
else
  echo "  FAIL: owner was refused" >&2; FAILED=1
fi

# Negative: an unprivileged user (nobody - not owner, not in the socket group) is refused by
# the 0660 perms. ctl should print a connect error and exit non-zero.
out="$(nssh "$a" "sudo -u nobody $CTL version 2>&1" || true)"
if printf '%s' "$out" | grep -qiE 'permission denied|cannot connect'; then
  log "  OK: unprivileged user refused at the socket ($(printf '%s' "$out" | grep -oiE 'permission denied' | head -1))"
else
  echo "  FAIL: unprivileged user was NOT refused (got: $(printf '%s' "$out" | head -1))" >&2; FAILED=1
fi

# ...and it exits non-zero (so the perms gate actually blocks, not just warns).
if nssh "$a" "sudo -u nobody $CTL version >/dev/null 2>&1"; then
  echo "  FAIL: unprivileged ctl exited 0" >&2; FAILED=1
else
  log "  OK: unprivileged ctl exits non-zero"
fi

[ "$FAILED" = 0 ] && { echo "qp-nebula sim ctl-negative: PASS (perms gate allows owner, refuses unprivileged)"; exit 0; } \
                  || { echo "qp-nebula sim ctl-negative: FAIL"; exit 1; }
