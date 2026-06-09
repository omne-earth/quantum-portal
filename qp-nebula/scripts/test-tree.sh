#!/usr/bin/env bash
# qp-nebula sim - level-3 binary NAT TREE (carrier-grade / nested NAT relay).
#
#   pub (root): lh1, lh2  (lighthouses + relays)
#     |-- R1a (NAT) --+-- R2a (NAT) -- tAA: leaf1 leaf2
#     |               +-- R2b (NAT) -- tAB: leaf3 leaf4
#     |-- R1b (NAT) --+-- R2c (NAT) -- tBA: leaf5 leaf6
#                     +-- R2d (NAT) -- tBB: leaf7 leaf8
#
# 8 leaves, each behind TWO nested NATs (R2 then R1). Two leaves in different L1
# subtrees share no IP path - they can only meet through a lighthouse RELAY. Same-
# segment leaves go direct. We assert the FULL 8-leaf overlay matrix (mix of direct +
# relayed pqIX). Both lighthouses relay + every leaf homes both, so this is failover-
# ready. nft direct-block (block_direct_underlay) layers on as defense in depth.
#
# 16 VMs. Tree segment nets are isolated pure-L2; addressing is STATIC, assigned over
# the mgmt channel by matching NICs via their fixed MACs. Routers do ip_forward +
# `masquerade fully-random` (symmetric). Run: make -f qp-nebula/Makefile stress-relay-tree
set -euo pipefail
LOG_TAG=tree
. "$(dirname "$0")/_common.sh"
FAILED=0
PORT=4242; OVL="10.99.0."

# ---- topology -----------------------------------------------------------------
LIGHTHOUSES=(lh1 lh2)
ROUTERS=(R1a R1b R2a R2b R2c R2d)
LEAVES=(leaf1 leaf2 leaf3 leaf4 leaf5 leaf6 leaf7 leaf8)
ALLVMS=("${LIGHTHOUSES[@]}" "${ROUTERS[@]}" "${LEAVES[@]}")

declare -A LH_PUBIP=( [lh1]=203.0.113.11 [lh2]=203.0.113.12 )
declare -A LH_MAC=(   [lh1]=52:54:00:b0:00:11 [lh2]=52:54:00:b0:00:12 )

# routers: UPNET UPIP UPMAC DOWNNET DOWNIP DOWNMAC MASQ DEFGW
declare -A R_UPNET=( [R1a]=pub [R1b]=pub [R2a]=tA [R2b]=tA [R2c]=tB [R2d]=tB )
declare -A R_UPIP=(  [R1a]=203.0.113.21 [R1b]=203.0.113.22 [R2a]=10.10.1.21 [R2b]=10.10.1.22 [R2c]=10.10.2.21 [R2d]=10.10.2.22 )
declare -A R_UPMAC=( [R1a]=52:54:00:b1:00:21 [R1b]=52:54:00:b1:00:22 [R2a]=52:54:00:b2:01:21 [R2b]=52:54:00:b2:01:22 [R2c]=52:54:00:b2:02:21 [R2d]=52:54:00:b2:02:22 )
declare -A R_DOWNNET=( [R1a]=tA [R1b]=tB [R2a]=tAA [R2b]=tAB [R2c]=tBA [R2d]=tBB )
declare -A R_DOWNIP=(  [R1a]=10.10.1.1 [R1b]=10.10.2.1 [R2a]=10.10.11.1 [R2b]=10.10.12.1 [R2c]=10.10.21.1 [R2d]=10.10.22.1 )
declare -A R_DOWNMAC=( [R1a]=52:54:00:b1:0a:01 [R1b]=52:54:00:b1:0b:01 [R2a]=52:54:00:b2:11:01 [R2b]=52:54:00:b2:12:01 [R2c]=52:54:00:b2:21:01 [R2d]=52:54:00:b2:22:01 )
declare -A R_MASQ=(  [R1a]=10.10.1.0/24 [R1b]=10.10.2.0/24 [R2a]=10.10.11.0/24 [R2b]=10.10.12.0/24 [R2c]=10.10.21.0/24 [R2d]=10.10.22.0/24 )
declare -A R_DEFGW=( [R1a]=203.0.113.1 [R1b]=203.0.113.1 [R2a]=10.10.1.1 [R2b]=10.10.1.1 [R2c]=10.10.2.1 [R2d]=10.10.2.1 )

# leaves: SEGNET SEGIP SEGMAC GW(=R2 downlink) OVERLAY
declare -A L_SEGNET=( [leaf1]=tAA [leaf2]=tAA [leaf3]=tAB [leaf4]=tAB [leaf5]=tBA [leaf6]=tBA [leaf7]=tBB [leaf8]=tBB )
declare -A L_SEGIP=(  [leaf1]=10.10.11.11 [leaf2]=10.10.11.12 [leaf3]=10.10.12.11 [leaf4]=10.10.12.12 [leaf5]=10.10.21.11 [leaf6]=10.10.21.12 [leaf7]=10.10.22.11 [leaf8]=10.10.22.12 )
declare -A L_SEGMAC=( [leaf1]=52:54:00:b3:11:11 [leaf2]=52:54:00:b3:11:12 [leaf3]=52:54:00:b3:12:11 [leaf4]=52:54:00:b3:12:12 [leaf5]=52:54:00:b3:21:11 [leaf6]=52:54:00:b3:21:12 [leaf7]=52:54:00:b3:22:11 [leaf8]=52:54:00:b3:22:12 )
declare -A L_GW=(     [leaf1]=10.10.11.1 [leaf2]=10.10.11.1 [leaf3]=10.10.12.1 [leaf4]=10.10.12.1 [leaf5]=10.10.21.1 [leaf6]=10.10.21.1 [leaf7]=10.10.22.1 [leaf8]=10.10.22.1 )

# globals for assert_matrix/expected_reachable: leaves are members homing both lighthouses.
QPN_SUFFIX="${QPN_SUFFIX:--tree}"
NAT_CIDRS=( 10.10.1.0/24 10.10.2.0/24 10.10.11.0/24 10.10.12.0/24 10.10.21.0/24 10.10.22.0/24 )

# ---- teardown (keep VMs on failure) -------------------------------------------
tree_destroy(){ local v d; for v in "${ALLVMS[@]}"; do d="$(dom "$v")"
  $VIRSH destroy "$d" 2>/dev/null || true; $VIRSH undefine "$d" --nvram 2>/dev/null || true
  rm -f "$QPN_IMG_DIR/$v${QPN_SUFFIX}.qcow2"; done; }
tree_exit(){ local rc=$?; [ "$rc" -ne 0 ] && { log "run FAILED (rc=$rc) - leaving VMs UP for debugging (make -C simulation clean to clear)"; return; }; [ "${QPN_KEEP:-0}" = 1 ] && { log "QPN_KEEP=1"; return; }; tree_destroy; }
tree_destroy; trap tree_exit EXIT

# ---- provision all 16 domains -------------------------------------------------
[ -f "$QPN_BASE" ] || die "base image missing - run 'make -C simulation base'"
RT="$SIM/domains/qp-nebula/tree-router.xml.template"; NT="$SIM/domains/qp-nebula/tree-node.xml.template"
provision_one(){ local v="$1" tmpl="$2"; shift 2; local d disk; d="$(dom "$v")"; disk="$QPN_IMG_DIR/$v${QPN_SUFFIX}.qcow2"
  qemu-img create -q -f qcow2 -F qcow2 -b "$QPN_BASE" "$disk"
  local sed_args=(-e "s|{{NODE}}|$d|g" -e "s|{{DISK}}|$disk|g"); local kv
  for kv in "$@"; do sed_args+=(-e "s|{{${kv%%=*}}}|${kv#*=}|g"); done
  sed "${sed_args[@]}" "$tmpl" > "$QPN_BUILD/$v${QPN_SUFFIX}.xml"
  $VIRSH define "$QPN_BUILD/$v${QPN_SUFFIX}.xml" >/dev/null; $VIRSH start "$d" >/dev/null; }
mkdir -p "$QPN_BUILD"
for v in "${LIGHTHOUSES[@]}"; do provision_one "$v" "$NT" "NET_NIC=pub" "MAC_NIC=${LH_MAC[$v]}"; done
for v in "${ROUTERS[@]}"; do provision_one "$v" "$RT" "NET_UP=${R_UPNET[$v]}" "MAC_UP=${R_UPMAC[$v]}" "NET_DOWN=${R_DOWNNET[$v]}" "MAC_DOWN=${R_DOWNMAC[$v]}"; done
for v in "${LEAVES[@]}"; do provision_one "$v" "$NT" "NET_NIC=${L_SEGNET[$v]}" "MAC_NIC=${L_SEGMAC[$v]}"; done
log "16 VMs provisioned; waiting for mgmt ssh"

# ---- discover mgmt addrs ------------------------------------------------------
declare -A MA
for v in "${ALLVMS[@]}"; do MA[$v]="$(wait_ssh "$(dom "$v")")" || die "$v never came up"; log "  $v mgmt=${MA[$v]}"; done

# nic_by_mac <mgmtaddr> <mac> -> guest iface name
nic_by_mac(){ nssh "$1" "ip -o link | grep -i '$2' | awk -F': ' '{print \$2}' | cut -d@ -f1 | head -1"; }

# set_static <mgmt> <iface> <cidr> - assign a STATIC addr that STICKS. Fedora Server's
# NetworkManager flushes manual addrs on managed devices, so mark the NIC unmanaged
# first (the isolated tree nets have no DHCP anyway), then assign.
set_static(){ nssh "$1" "nmcli dev set $2 managed no 2>/dev/null || true; ip addr flush dev $2 2>/dev/null || true; ip addr add $3 dev $2; ip link set $2 up"; }

# ---- configure ROUTERS: static NICs + ip_forward + symmetric masquerade -------
for v in "${ROUTERS[@]}"; do a="${MA[$v]}"
  upif="$(nic_by_mac "$a" "${R_UPMAC[$v]}")"; dnif="$(nic_by_mac "$a" "${R_DOWNMAC[$v]}")"
  [ -n "$upif" ] && [ -n "$dnif" ] || die "$v: could not map up/down NICs by MAC"
  set_static "$a" "$upif" "${R_UPIP[$v]}/24"
  set_static "$a" "$dnif" "${R_DOWNIP[$v]}/24"
  nssh "$a" "ip route replace default via ${R_DEFGW[$v]}; \
             sysctl -qw net.ipv4.ip_forward=1; \
             firewall-cmd -q --zone=trusted --change-interface=$upif; \
             firewall-cmd -q --zone=trusted --change-interface=$dnif"
  # symmetric masquerade (fully-random) of the downlink subnet out the uplink NIC.
  printf 'table ip qpnnat {\n chain post { type nat hook postrouting priority 100; policy accept;\n  ip saddr %s oifname "%s" masquerade fully-random\n }\n}\n' "${R_MASQ[$v]}" "$upif" \
    | nssh "$a" "nft -f -" || die "$v: masquerade install failed"
  log "  $v routing up=$upif(${R_UPIP[$v]}) down=$dnif(${R_DOWNIP[$v]}) masq ${R_MASQ[$v]}"
done

# ---- configure LIGHTHOUSES: static pub NIC -----------------------------------
declare -A MGMT OVERLAY ROLE
declare -gA LH_SET
i=100
for v in "${LIGHTHOUSES[@]}"; do a="${MA[$v]}"
  pif="$(nic_by_mac "$a" "${LH_MAC[$v]}")"; [ -n "$pif" ] || die "$v: pub NIC not found"
  set_static "$a" "$pif" "${LH_PUBIP[$v]}/24"
  i=$((i+1)); MGMT[$v]="$a"; OVERLAY[$v]="${OVL}${i}"; ROLE[$v]=lighthouse
done

# ---- configure LEAVES: static seg NIC + default route up the tree -------------
j=0
for v in "${LEAVES[@]}"; do a="${MA[$v]}"
  sif="$(nic_by_mac "$a" "${L_SEGMAC[$v]}")"; [ -n "$sif" ] || die "$v: seg NIC not found"
  set_static "$a" "$sif" "${L_SEGIP[$v]}/24"
  nssh "$a" "ip route replace default via ${L_GW[$v]} dev $sif"
  j=$((j+1)); MGMT[$v]="$a"; OVERLAY[$v]="${OVL}${j}"; ROLE[$v]=node; LH_SET[$v]="lh1 lh2"
done
LH_SET[lh1]="lh2"; LH_SET[lh2]="lh1"

# ---- nebula: build, certs, configs, push, start (leaves + lighthouses) --------
mkdir -p "$PKI" "$CFG"
rm -f "$PKI"/*.crt "$PKI"/*.key 2>/dev/null || true
"$BIN/nebula-cert" ca -name "qp-nebula tree CA" -curve MLDSA87 -duration 8760h -out-crt "$PKI/ca.crt" -out-key "$PKI/ca.key"
NODES_NEB=("${LIGHTHOUSES[@]}" "${LEAVES[@]}")
for v in "${NODES_NEB[@]}"; do
  "$BIN/nebula-cert" sign -ca-crt "$PKI/ca.crt" -ca-key "$PKI/ca.key" -name "$v" -networks "${OVERLAY[$v]}/24" -out-crt "$PKI/$v.crt" -out-key "$PKI/$v.key"
done
# static_host_map + lighthouse hosts (both lighthouses, at their pub addrs).
SHM="\"${OVERLAY[lh1]}\": [\"${LH_PUBIP[lh1]}:$PORT\"], \"${OVERLAY[lh2]}\": [\"${LH_PUBIP[lh2]}:$PORT\"]"
HOSTS="\"${OVERLAY[lh1]}\", \"${OVERLAY[lh2]}\""
for v in "${NODES_NEB[@]}"; do a="${MGMT[$v]}"
  if [ "${ROLE[$v]}" = lighthouse ]; then
    other=lh2; [ "$v" = lh2 ] && other=lh1
    cat > "$CFG/$v.yml" <<YAML
pki: {ca: $D_DIR/ca.crt, cert: $D_DIR/$v.crt, key: $D_DIR/$v.key}
static_host_map: {"${OVERLAY[$other]}": ["${LH_PUBIP[$other]}:$PORT"]}
lighthouse: {am_lighthouse: true, hosts: ["${OVERLAY[$other]}"]}
listen: {host: 0.0.0.0, port: $PORT}
punchy: {punch: true}
relay: {am_relay: true, use_relays: false}
tun: {dev: nebula1, mtu: 1300}
firewall: {outbound: [{port: any, proto: any, host: any}], inbound: [{port: any, proto: any, host: any}]}
logging: {level: info}
YAML
  else
    cat > "$CFG/$v.yml" <<YAML
pki: {ca: $D_DIR/ca.crt, cert: $D_DIR/$v.crt, key: $D_DIR/$v.key}
static_host_map: {$SHM}
lighthouse: {am_lighthouse: false, hosts: [$HOSTS]}
listen: {host: 0.0.0.0, port: $PORT}
punchy: {punch: true}
relay: {am_relay: false, use_relays: true, relays: [$HOSTS]}
tun: {dev: nebula1, mtu: 1300}
firewall: {outbound: [{port: any, proto: any, host: any}], inbound: [{port: any, proto: any, host: any}]}
logging: {level: info}
YAML
  fi
  # The config is rendered above into $CFG/$v.yml; push_node does the rest, mode-aware
  # (rpm-install + packaged unit under stress, .build binary confined by hand under smoke).
  push_node "$v"
done

# ---- defense in depth: nft-block direct leaf<->leaf underlay (best-effort) -----
# (Real nested NAT already prevents a direct path; this is the retained DiD layer.)
for v in "${LEAVES[@]}"; do a="${MGMT[$v]}"
  rules=$'table inet qpn {\n  chain qpnout { type filter hook output priority 0; policy accept;\n'
  for w in "${LEAVES[@]}"; do [ "$w" = "$v" ] && continue; [ "${L_SEGNET[$w]}" = "${L_SEGNET[$v]}" ] && continue
    rules+="    ip daddr ${L_SEGIP[$w]} udp dport ${PORT} drop"$'\n'; done
  rules+=$'  }\n}\n'
  printf '%s' "$rules" | nssh "$a" "nft -f -" 2>/dev/null || true
done

# ---- assert the full 8-leaf overlay matrix (direct + relayed) -----------------
log "asserting full 8-leaf overlay matrix (DEADLINE 90s/pair)"
tally="$(DEADLINE=90 assert_matrix "${LEAVES[@]}")" || FAILED=1; log "leaf reachability: $tally"
# pqIX confirmation + cross-subtree relay confirmation, from a leaf's own journal.
nssh "${MGMT[leaf1]}" "journalctl -u $D_UNIT --no-pager | grep -q 'style:pqix'" \
  && log "leaf1: tunnels are pqIX (ML-KEM-1024)" || { echo "  FAIL  leaf1: not pqIX" >&2; FAILED=1; }
nssh "${MGMT[leaf1]}" "journalctl -u $D_UNIT --no-pager | grep -qiE 'relay'" \
  && log "leaf1: relay path in use (cross-subtree)" || { echo "  FAIL  leaf1: no relay activity" >&2; FAILED=1; }

[ "$FAILED" = 0 ] && { echo "qp-nebula sim NAT-tree: PASS (level-3 binary tree, $tally leaves reachable, pqIX, relayed cross-subtree)"; exit 0; } \
                  || { echo "qp-nebula sim NAT-tree: FAIL"; exit 1; }
