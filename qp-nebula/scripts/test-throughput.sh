#!/usr/bin/env bash
# qp-nebula sim - data-plane throughput over a pqIX tunnel, VM-to-VM. Brings up the
# tunnel topology (1 lighthouse + 1 node = two VMs), then runs qp-tput (the stdlib-only
# probe) across the OVERLAY: server on one node, client on the other, receiver-measured
# Gbit/s. The handshake is post-quantum (ML-KEM-1024 + ML-DSA-87); the data plane is
# AES-256-GCM. Replaces the host-netns stress-throughput.sh.
#   run-throughput.sh <inventory.env>   (use inventory/tunnel.env)
# Env: DUR=seconds (default 10), QPN_KEEP=1.
set -euo pipefail
LOG_TAG=throughput
. "$(dirname "$0")/_common.sh"
INV="${1:?usage: run-throughput.sh <inventory.env>}"
FAILED=0
. "$INV"; destroy_nodes; trap on_exit EXIT

topology_up "$INV"
log "asserting tunnel up (DEADLINE ${DEADLINE:-60}s)"
tally="$(assert_matrix)" || FAILED=1; log "overlay reachability: $tally"
assert_pqix
[ "$FAILED" = 0 ] || { echo "qp-nebula sim throughput: FAIL (tunnel did not form)"; exit 1; }

# pick two distinct nodes: client = first, server = second.
names=(); for e in "${NODES[@]}"; do names+=("${e%%:*}"); done
[ "${#names[@]}" -ge 2 ] || die "throughput needs >=2 nodes (use inventory/tunnel.env)"
C="${names[0]}"; S="${names[1]}"; DUR="${DUR:-10}"; TPORT=5201

log "qp-tput overlay: server=$S(${OVERLAY[$S]}) client=$C, ${DUR}s"
nssh "${MGMT[$S]}" "systemd-run --unit=qptput --collect $D_TPUT -s -B ${OVERLAY[$S]} -p $TPORT" >/dev/null
sleep 2
nssh "${MGMT[$C]}" "$D_TPUT -c -h ${OVERLAY[$S]} -p $TPORT -t $DUR" >/dev/null 2>&1 || true
sleep 2
RES="$(nssh "${MGMT[$S]}" "journalctl -u qptput --no-pager | grep -oE 'RESULT [0-9.]+ Gbits/sec' | tail -1" || true)"
[ -n "$RES" ] && { echo "qp-nebula sim throughput: PASS - pqIX OVERLAY ${RES#RESULT }"; exit 0; } \
              || { echo "qp-nebula sim throughput: FAIL - no qp-tput result"; exit 1; }
