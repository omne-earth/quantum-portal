#!/usr/bin/env bash
# qp-nebula sim - bring up a tunnel/mesh topology across REAL VMs (one node = one VM)
# and assert the overlay reachability matrix. Replaces the old host-netns scripts: the
# topology that used `ip netns`/veth is now separate machines on the isolated
# node net, so the pqIX tunnel forms VM-to-VM over a real UDP underlay.
#   run.sh <inventory.env>
# Env: LOSS=% DELAY=ms (netem on each underlay NIC), QPN_KEEP=1 (leave VMs up).
set -euo pipefail
LOG_TAG=run
. "$(dirname "$0")/_common.sh"
INV="${1:?usage: run.sh <inventory.env>}"
FAILED=0
. "$INV"; destroy_nodes; trap on_exit EXIT   # clean slate; teardown on success, keep on failure

topology_up "$INV"
log "asserting overlay reachability (DEADLINE ${DEADLINE:-60}s)"
tally="$(assert_matrix)" || FAILED=1; log "overlay reachability: $tally"
assert_pqix

[ "$FAILED" = 0 ] && { echo "qp-nebula sim: PASS ($tally overlay reachable, pqIX)"; exit 0; } \
                  || { echo "qp-nebula sim: FAIL"; exit 1; }
