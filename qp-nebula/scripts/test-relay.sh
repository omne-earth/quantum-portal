#!/usr/bin/env bash
# qp-nebula sim - relayed pqIX. The two node VMs cannot reach each other directly on
# the underlay (an nft rule drops node-to-node UDP/4242; only the lighthouse/relay is
# reachable), so node-to-node overlay traffic MUST go through the relay. Proves a pqIX
# tunnel converges over a relay. Replaces the host-netns symmetric-NAT relay path
# (firewall-forced relay instead of NAT, same outcome: no direct path).
#   run-relay.sh <inventory.env>   (use inventory/relay.env)
# Env: QPN_KEEP=1.
set -euo pipefail
LOG_TAG=relay
. "$(dirname "$0")/_common.sh"
INV="${1:?usage: run-relay.sh <inventory.env>}"
FAILED=0
. "$INV"; destroy_nodes; trap on_exit EXIT

export RELAY=1                          # render_cfg adds relay: am_relay / use_relays
topology_up "$INV"
block_direct_underlay                   # drop direct node<->node underlay UDP

# assert reachability among the non-lighthouse nodes (forced through the relay).
nodes=(); for e in "${NODES[@]}"; do n="${e%%:*}"; [ "${ROLE[$n]}" != lighthouse ] && nodes+=("$n"); done
[ "${#nodes[@]}" -ge 2 ] || die "relay needs >=2 non-lighthouse nodes (use inventory/relay.env)"
log "asserting relayed reachability among: ${nodes[*]} (DEADLINE 120s)"
tally="$(DEADLINE=120 assert_matrix "${nodes[@]}")" || FAILED=1; log "relayed reachability: $tally"
assert_pqix

# confirm a relay was actually used (nebula logs relay establishment on the node side).
a="${MGMT[${nodes[0]}]}"
nssh "$a" "journalctl -u $D_UNIT --no-pager | grep -qiE 'relay'" \
  && log "${nodes[0]}: relay path in use" || { echo "  FAIL  ${nodes[0]}: no relay activity logged"; FAILED=1; }

[ "$FAILED" = 0 ] && { echo "qp-nebula sim relay: PASS (relayed pqIX, direct blocked, $tally)"; exit 0; } \
                  || { echo "qp-nebula sim relay: FAIL"; exit 1; }
