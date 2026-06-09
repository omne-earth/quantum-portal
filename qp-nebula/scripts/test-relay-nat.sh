#!/usr/bin/env bash
# qp-nebula sim - relayed pqIX over REAL symmetric NAT. Each node sits behind its OWN
# libvirt NAT (nat1/nat2); the relay/lighthouse is on the routed public segment
# (pub). Two nodes behind separate NATs have no inbound mapping for each other (and
# --random-fully makes the mapping symmetric), so direct + hole-punch fail and nebula
# MUST relay n1<->n2 through lh1. The nft direct-block (block_direct_underlay) is also
# applied as DEFENSE IN DEPTH. This is the faithful version of stress-relay (which uses
# the nft block alone).
#   run-relay-nat.sh <inventory.env>   (use inventory/relay-nat.env)
# Env: QPN_KEEP=1.
set -euo pipefail
LOG_TAG=relay-nat
. "$(dirname "$0")/_common.sh"
INV="${1:?usage: run-relay-nat.sh <inventory.env>}"
FAILED=0
. "$INV"                              # NODES, LH_SET, NET, NAT_CIDRS, PORT, OVL_PREFIX
destroy_nodes
# Always remove the host NAT rules; keep VMs only on failure (debugging).
relaynat_exit(){
  local rc=$?
  teardown_symmetric_nat "${NAT_CIDRS[@]}"
  [ "$rc" -ne 0 ] && { log "run FAILED (rc=$rc) - leaving VMs UP for debugging (rerun, or 'make -C simulation clean')"; return; }
  teardown_nodes
}
trap relaynat_exit EXIT

export RELAY=1                        # render_cfg adds relay: am_relay / use_relays
setup_symmetric_nat "${NAT_CIDRS[@]}" # true symmetric NAT (random-fully) over the double-NAT
topology_up "$INV"
block_direct_underlay                 # DEFENSE IN DEPTH on top of the real NAT

nodes=(); for e in "${NODES[@]}"; do n="${e%%:*}"; [ "${ROLE[$n]}" != lighthouse ] && nodes+=("$n"); done
[ "${#nodes[@]}" -ge 2 ] || die "relay-nat needs >=2 non-lighthouse nodes"
log "asserting relayed reachability across real NAT among: ${nodes[*]} (DEADLINE 150s)"
tally="$(DEADLINE=150 assert_matrix "${nodes[@]}")" || FAILED=1; log "relayed reachability: $tally"
assert_pqix

a="${MGMT[${nodes[0]}]}"
nssh "$a" "journalctl -u $D_UNIT --no-pager | grep -qiE 'relay'" \
  && log "${nodes[0]}: relay path in use" || { echo "  FAIL  ${nodes[0]}: no relay activity logged" >&2; FAILED=1; }

[ "$FAILED" = 0 ] && { echo "qp-nebula sim relay-nat: PASS (real symmetric NAT, relayed pqIX, $tally)"; exit 0; } \
                  || { echo "qp-nebula sim relay-nat: FAIL"; exit 1; }
