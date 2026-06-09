#!/usr/bin/env bash
# qp-nebula sim - exercise `nebula ctl` over a FORWARDED control socket: the REMOTE admin path.
# The control socket has no network listener (local-only by design); remote control = forward
# the unix socket over ssh, then point ctl at the local forwarded socket. Production forwards
# over qp-ssh (full PQ-KEX): `qp-ssh -L /tmp/neb.sock:/run/nebula.sock admin@node`. The sim
# proves the same -L unix-socket-forward MECHANISM using its provision ssh (the nodes run a
# stock sshd, so qp-ssh can't PQ-handshake them - the forwarding behaviour is identical).
set -euo pipefail
LOG_TAG=run
. "$(dirname "$0")/_common.sh"
INV="${1:?usage: test-ctl-remote.sh <inventory.env>}"
FAILED=0
. "$INV"; destroy_nodes; trap on_exit EXIT

topology_up "$INV"
tally="$(assert_matrix)" || FAILED=1; log "overlay reachability: $tally"

n="${NODES[0]%%:*}"; a="${MGMT[$n]}"
LSOCK="$QPN_BUILD/ctl-remote.sock"; rm -f "$LSOCK"

# Forward $n:/run/nebula.sock -> $LSOCK on this host. Backgrounded; cleaned up (with the VMs)
# on exit while PRESERVING the script's exit code so on_exit's success-only teardown is honored.
log "forwarding $n:$D_SOCK -> $LSOCK (ssh -L unix)"
ssh "${SSH_OPTS[@]}" -L "$LSOCK:$D_SOCK" -N "root@$a" &
FWD_PID=$!
on_exit_remote(){ local rc=$?; kill "$FWD_PID" 2>/dev/null || true; rm -f "$LSOCK" 2>/dev/null || true; trap - EXIT; ( exit "$rc" ); on_exit; }
trap on_exit_remote EXIT

for _ in $(seq 1 20); do [ -S "$LSOCK" ] && break; sleep 0.5; done
[ -S "$LSOCK" ] || { echo "  FAIL: forwarded socket never appeared" >&2; FAILED=1; }

# Run the host's nebula binary against the FORWARDED socket - i.e. drive the remote daemon.
CTL="$BIN/qp-nebula ctl -socket $LSOCK"
check(){
  local desc="$1" cmd="$2" pat="$3" out
  out="$($cmd 2>/dev/null || true)"
  if printf '%s' "$out" | grep -qE "$pat"; then log "  OK: $desc"; else echo "  FAIL: $desc (got: $(printf '%s' "$out" | head -1))" >&2; FAILED=1; fi
}
log "driving the remote daemon's ctl via the forward"
check "remote version"               "$CTL version"      '.'
check "remote list-hostmap (peer)"   "$CTL list-hostmap" '[0-9]+\.[0-9]+'
check "remote help"                  "$CTL help"         'list-hostmap'

[ "$FAILED" = 0 ] && { echo "qp-nebula sim ctl-remote: PASS (nebula ctl over a forwarded control socket)"; exit 0; } \
                  || { echo "qp-nebula sim ctl-remote: FAIL"; exit 1; }
