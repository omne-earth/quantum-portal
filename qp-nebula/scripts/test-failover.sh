#!/usr/bin/env bash
# qp-nebula sim - lighthouse failover. Brings up the mesh (2 lighthouses + 3 nodes),
# proves full reachability, then `virsh destroy`s one lighthouse VM and re-asserts that
# the DUAL-HOMED nodes still reach each other via the survivor. Single-homed nodes on
# the killed lighthouse are expected to lose new discovery (not asserted). Replaces the
# host-netns failover path.
#   run-failover.sh <inventory.env>   (use inventory/mesh.env)
# Env: FAILOVER=<lighthouse name> (default lh1), QPN_KEEP=1.
set -euo pipefail
LOG_TAG=failover
. "$(dirname "$0")/_common.sh"
INV="${1:?usage: run-failover.sh <inventory.env>}"
FAILED=0
. "$INV"; destroy_nodes; trap on_exit EXIT

topology_up "$INV"
tally="$(DEADLINE=90 assert_matrix)" || FAILED=1; log "initial reachability: $tally"
assert_pqix
[ "$FAILED" = 0 ] || { echo "qp-nebula sim failover: FAIL (mesh did not converge)"; exit 1; }

KILL="${FAILOVER:-lh1}"; [ "${ROLE[$KILL]:-}" = lighthouse ] || die "$KILL is not a lighthouse"
log "killing lighthouse $KILL ($(dom "$KILL"))"
$VIRSH destroy "$(dom "$KILL")" 2>/dev/null || true

# survivors = non-lighthouse nodes that still have a lighthouse other than $KILL.
surv=()
for e in "${NODES[@]}"; do n="${e%%:*}"; [ "${ROLE[$n]}" = lighthouse ] && continue
  for lh in ${LH_SET[$n]:-}; do [ "$lh" != "$KILL" ] && { surv+=("$n"); break; }; done
done
[ "${#surv[@]}" -ge 2 ] || die "need >=2 dual-homed survivors (use inventory/mesh.env)"
log "re-asserting among survivors: ${surv[*]} (DEADLINE 120s)"
tally="$(DEADLINE=120 assert_matrix "${surv[@]}")" || FAILED=1; log "post-failover reachability: $tally"

[ "$FAILED" = 0 ] && { echo "qp-nebula sim failover: PASS (survivors $tally via the surviving lighthouse)"; exit 0; } \
                  || { echo "qp-nebula sim failover: FAIL"; exit 1; }
