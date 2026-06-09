#!/usr/bin/env bash
# qp sim - CORE helpers, shared by the three VM-lifecycle drivers and nothing else:
#   build-base.sh  - build the golden base image
#   provision.sh   - CoW-clone the base into the inventory's node VMs and boot them
#   runner.sh      - boot one node, install rpm(s), run a deployment-tier check in it
# Standalone: no dependency on any other repo. All host/site specifics come from the
# environment (QPN_* vars), defaulted here.
#
# The qp-nebula overlay-topology layer (cert minting, config render/push, reachability
# matrix, relay/NAT orchestration) is NOT here - it builds ON these and lives in
# qp-nebula/scripts/_common.sh, which sources this file first.

VIRSH="virsh -q -c qemu:///system"

QPN_IMG_DIR="${QPN_IMG_DIR:-/var/lib/libvirt/images/qp-nebula}"
QPN_BASE="$QPN_IMG_DIR/base.qcow2"

SIM="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QPN_BUILD="$SIM/.build"
QPN_KEY="$SIM/.ssh/provision_key"

NET_MGMT="mgmt"
NET_UNDERLAY="node"
MGMT_PREFIX="192.168.140."
DOM_PREFIX="${DOM_PREFIX:-qp}"   # domain (VM) name prefix; each component's test passes its own (qpssh, qpstunnel, ...)

# Per-node underlay net override, set by an inventory (e.g. relay-nat puts nodes on
# per-node NAT nets); empty default means every node uses $NET_UNDERLAY. Declared here
# because provision.sh reads it.
declare -gA NET

SSH_OPTS=(-i "$QPN_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o ConnectTimeout=5 -o LogLevel=ERROR)

log(){ printf '[%s] %s\n' "${LOG_TAG:-sim}" "$*"; }
die(){ printf '[%s] ERROR: %s\n' "${LOG_TAG:-sim}" "$*" >&2; exit 1; }

dom(){ printf '%s-%s%s' "$DOM_PREFIX" "$1" "${QPN_SUFFIX:-}"; }

# Discover a guest NIC address (via the qemu guest agent) matching an ipv4 prefix.
guest_addr(){
  local d="$1" pfx="$2"
  $VIRSH domifaddr "$d" --source agent 2>/dev/null \
    | awk '{print $4}' | sed 's#/.*##' | grep -m1 -F "$pfx" || true
}

# Block until a node's mgmt addr is up AND sshable. Echoes the addr.
wait_ssh(){
  local d="$1" addr="" i
  for i in $(seq 1 120); do
    addr="$(guest_addr "$d" "$MGMT_PREFIX")"
    if [ -n "$addr" ] && ssh "${SSH_OPTS[@]}" "root@$addr" true 2>/dev/null; then
      printf '%s' "$addr"; return 0
    fi
    sleep 2
  done
  return 1
}

nssh(){ local addr="$1"; shift; ssh "${SSH_OPTS[@]}" "root@$addr" "$@"; }
npush(){ local addr="$1" src="$2" dst="$3"; scp "${SSH_OPTS[@]}" -r "$src" "root@$addr:$dst"; }

# destroy_nodes - UNCONDITIONALLY destroy/undefine + rm-disk every node domain in the
# current inventory. Called at the START of each run (clean slate after a prior failure)
# and by teardown_nodes at the end.
destroy_nodes(){
  local entry d
  for entry in "${NODES[@]}"; do d="$(dom "${entry%%:*}")"
    $VIRSH destroy "$d" 2>/dev/null || true
    $VIRSH undefine "$d" --nvram 2>/dev/null || true
    rm -f "$QPN_IMG_DIR/${entry%%:*}${QPN_SUFFIX:-}.qcow2"
  done
}

# teardown_nodes - end-of-run cleanup; honors QPN_KEEP=1 (leave VMs up for inspection).
teardown_nodes(){
  [ "${QPN_KEEP:-0}" = 1 ] && { log "QPN_KEEP=1 - leaving VMs up"; return; }
  destroy_nodes
}

# on_exit - the EXIT trap. ONLY tears down on SUCCESS. A failed run leaves its libvirt
# artifacts UP for debugging (ssh in via the mgmt addr, check journalctl -u qpn); the
# NEXT run's start-of-run destroy_nodes clears them, or `make -C simulation clean`.
on_exit(){
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    log "run FAILED (rc=$rc) - leaving VMs UP for debugging (rerun, or 'make -C simulation clean', to clear)"
    return
  fi
  teardown_nodes
}
