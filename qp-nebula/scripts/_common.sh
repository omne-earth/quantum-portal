#!/usr/bin/env bash
# qp-nebula sim - overlay-TOPOLOGY layer. Sourced by the test-*.sh drivers
# (test-mesh, test-relay, test-relay-nat, test-tree, test-throughput, test-failover).
# Builds the static qp-nebula binary, boots the inventory's nodes, mints the PQ CA +
# per-node certs, renders + pushes config, starts the daemons, and asserts overlay
# reachability (incl. relay/double-NAT orchestration).
#
# The generic VM lifecycle + ssh helpers this stands on (build/provision/boot, dom,
# wait_ssh, nssh, npush, destroy/on_exit, the QPN_* vars) come from the sim CORE, sourced
# first. Only nebula-specific state and orchestration live below.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../simulation/scripts" && pwd)/common.sh"

ULAY_PREFIX="10.42.0."

# The guest binaries are compiled by `make -f qp-nebula/Makefile build` (toolbox); the sim
# reads them from $BIN. PKI/CFG hold this run's generated certs + node configs.
BIN="${QPN_BIN:-$QPN_BUILD/bin}"; PKI="$QPN_BUILD/pki"; CFG="$QPN_BUILD/cfg"

# The qp-nebula component dir (this file is qp-nebula/scripts/_common.sh) + its built
# SELinux module. The daemon on every node runs CONFINED in qp_nebula_t: push_node
# loads this .pp, labels the node's files, and starts the labeled binary so systemd
# transitions init_t -> qp_nebula_t. QPN_SELINUX governs the mode: `enforcing`
# (default), `permissive` (the policy shakedown - collect AVCs without blocking), or
# `off` (skip confinement entirely). Built by `make -f qp-nebula/Makefile selinux`.
QPN_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QPN_PP="$QPN_HERE/selinux/qp_nebula.pp"

# Provisioning mode, set by the Makefile per target. STRESS targets pass QPN_RPM=<host path
# to the signed rpm>: each node dnf-installs it and runs the SHIPPED systemd unit (real
# %post SELinux load + RuntimeDirectory control socket + packaged /usr/local/qp layout) -
# parity with how qp-ssh/qp-stunnel validate at the stress tier. SMOKE targets leave
# QPN_RPM unset and get the .build binary, confined by hand (semodule/chcon + systemd-run).
# The per-mode daemon binary / unit / control socket / config+cert dir / tput probe flow
# into render_cfg, push_node, assert_pqix, and the test-*.sh drivers via D_BIN/D_UNIT/
# D_SOCK/D_DIR/D_TPUT.
if [ -n "${QPN_RPM:-}" ]; then
  PROV=rpm
  D_DIR=/usr/local/qp/etc/nebula; D_BIN=/usr/local/qp/sbin/qp-nebula; D_TPUT=/usr/local/qp/sbin/qp-tput; D_UNIT=qp-nebula; D_SOCK=/run/nebula/nebula.sock
else
  PROV=build
  D_DIR=/opt/qpn;                 D_BIN=/opt/qpn/qp-nebula;            D_TPUT=/opt/qpn/qp-tput;            D_UNIT=qpn;        D_SOCK=/run/nebula.sock
fi
export D_BIN D_UNIT D_SOCK D_DIR D_TPUT PROV

# ---- topology orchestration (shared by every test-*.sh) ---------------------
# Globals populated by topology_up: NODES, ROLE, MGMT, ULAY, OVERLAY, PORT, OVL.
# (NET - the per-node underlay net override - is declared in the core, read by provision.)
declare -gA ROLE MGMT ULAY OVERLAY

# Discover a guest's UNDERLAY ipv4 = the address that is NOT the mgmt net (and not
# loopback/link-local). Robust across underlay nets (node 10.42.0.x, the
# per-node NAT nets 192.168.16x.x, or the relay's pub 203.0.113.x).
underlay_addr(){
  local d="$1"
  $VIRSH domifaddr "$d" --source agent 2>/dev/null \
    | awk '{print $4}' | sed 's#/.*##' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
    | grep -v "^${MGMT_PREFIX}" | grep -vE '^(127\.|169\.254\.)' | head -1
}

# topology_up <inventory.env> - boot the node VMs, mint certs, push, start daemons.
# Env knobs: LOSS/DELAY (netem), RELAY=1 (relay config + block direct underlay).
topology_up(){
  local inv="$1"; . "$inv"            # NODES, LH_SET, PORT, OVL_PREFIX
  PORT="${PORT:-4242}"; OVL="${OVL_PREFIX:-10.99.0.}"
  "$SIM/scripts/provision.sh" "$inv"

  local i=0 entry n d u
  for entry in "${NODES[@]}"; do
    n="${entry%%:*}"; ROLE[$n]="${entry##*:}"; d="$(dom "$n")"
    i=$((i+1)); OVERLAY[$n]="${OVL}${i}"
    log "waiting for $d (ssh + underlay)"
    MGMT[$n]="$(wait_ssh "$d")" || die "$d never came up on mgmt"
    u=""; for _ in $(seq 1 30); do u="$(underlay_addr "$d")"; [ -n "$u" ] && break; sleep 2; done
    [ -n "$u" ] || die "$d has no underlay address"
    ULAY[$n]="$u"
    log "  $n  mgmt=${MGMT[$n]}  underlay=$u  overlay=${OVERLAY[$n]}"
  done

  # PKI (certs) + CFG (node configs) are this run's generated artifacts (the binaries come
  # pre-built from `make build`). nebula-cert refuses to overwrite keys - clear prior material.
  mkdir -p "$PKI" "$CFG"
  rm -f "$PKI"/*.crt "$PKI"/*.key 2>/dev/null || true
  "$BIN/nebula-cert" ca -name "qp-nebula sim CA" -curve MLDSA87 -duration 8760h \
    -out-crt "$PKI/ca.crt" -out-key "$PKI/ca.key"
  for entry in "${NODES[@]}"; do n="${entry%%:*}"
    "$BIN/nebula-cert" sign -ca-crt "$PKI/ca.crt" -ca-key "$PKI/ca.key" \
      -name "$n" -networks "${OVERLAY[$n]}/24" -out-crt "$PKI/$n.crt" -out-key "$PKI/$n.key"
  done

  for entry in "${NODES[@]}"; do n="${entry%%:*}"; render_cfg "$n"; push_node "$n"; done
}

# render_cfg <node> - write $CFG/<node>.yml. Honors RELAY (am_relay / use_relays).
render_cfg(){
  local n="$1" lh hosts="" shm="" amlh=false relay=""
  [ "${ROLE[$n]}" = lighthouse ] && amlh=true
  for lh in ${LH_SET[$n]:-}; do
    hosts+="${hosts:+, }\"${OVERLAY[$lh]}\""
    shm+="${shm:+, }\"${OVERLAY[$lh]}\": [\"${ULAY[$lh]}:$PORT\"]"
  done
  if [ "${RELAY:-0}" = 1 ]; then
    if [ "${ROLE[$n]}" = lighthouse ]; then
      relay=$'\nrelay: {am_relay: true, use_relays: false}'
    else
      local rl=""; for lh in ${LH_SET[$n]:-}; do rl+="${rl:+, }\"${OVERLAY[$lh]}\""; done
      relay=$'\nrelay: {am_relay: false, use_relays: true, relays: ['"$rl"']}'
    fi
  fi
  cat > "$CFG/$n.yml" <<YAML
pki: {ca: $D_DIR/ca.crt, cert: $D_DIR/$n.crt, key: $D_DIR/$n.key}
static_host_map: {$shm}
lighthouse: {am_lighthouse: $amlh, hosts: [$hosts]}
listen: {host: 0.0.0.0, port: $PORT}
punchy: {punch: true}
tun: {dev: nebula1, mtu: 1300}
firewall: {outbound: [{port: any, proto: any, host: any}], inbound: [{port: any, proto: any, host: any}]}
logging: {level: info}
control: {socket: $D_SOCK}$relay
YAML
}

# selinux_confine <mgmt> <node> - load qp_nebula_t in the VM and label THIS node's
# files so the daemon (started next) transitions init_t -> qp_nebula_t. The /opt/qpn
# layout is not in the .fc, so the file contexts are set explicitly (chcon) rather
# than via restorecon; the control socket /run/nebula.sock is labeled by the policy's
# /run name transition when the daemon creates it. Mode = QPN_SELINUX (default
# enforcing). Idempotent; safe per node. A no-op if SELinux is off in the guest.
selinux_confine(){
  local a="$1" n="$2" mode="${QPN_SELINUX:-enforcing}"
  [ "$mode" = off ] && return 0
  nssh "$a" 'selinuxenabled 2>/dev/null' || { log "  $n: SELinux disabled in guest - confine skipped"; return 0; }
  [ -f "$QPN_PP" ] || die "SELinux module missing: $QPN_PP (run: make -f qp-nebula/Makefile selinux)"
  npush "$a" "$QPN_PP" /tmp/qp_nebula.pp
  nssh "$a" "semodule -i /tmp/qp_nebula.pp"
  nssh "$a" "semanage port -a -t qp_nebula_port_t -p udp $PORT 2>/dev/null \
             || semanage port -m -t qp_nebula_port_t -p udp $PORT 2>/dev/null || true"
  nssh "$a" "chcon -t qp_nebula_exec_t /opt/qpn/qp-nebula; \
             chcon -t qp_nebula_etc_t  /opt/qpn/config.yml /opt/qpn/ca.crt /opt/qpn/$n.crt; \
             chcon -t qp_nebula_key_t  /opt/qpn/$n.key"
  # Keep the SYSTEM enforcing; scope the mode to qp_nebula_t only. `permissive` marks
  # JUST the domain permissive (collect its AVCs without blocking it, rest of system
  # still enforced); `enforcing` clears that mark. So the shakedown never weakens the
  # whole guest, and the enforcing run is a true per-domain enforce.
  nssh "$a" "setenforce 1"
  if [ "$mode" = permissive ]; then
    nssh "$a" "semanage permissive -a qp_nebula_t 2>/dev/null || true"
  else
    nssh "$a" "semanage permissive -d qp_nebula_t 2>/dev/null || true"
  fi
  log "  $n: confined (qp_nebula_t, SELinux $mode)"
}

# push_node <node> - provision + start the daemon. PROV=rpm installs the SHIPPED rpm and
# runs the packaged unit (stress); PROV=build pushes the .build binary, confines it by hand,
# and systemd-runs it (smoke). Both then open the firewall, apply netem, and trust the tun.
push_node(){
  local n="$1"; local a="${MGMT[$n]}"
  if [ "$PROV" = rpm ]; then
    # dnf-install the local rpm (no repos/deps needed - standalone). Its %post loads the .pp,
    # labels udp/$PORT, makes the qp-nebula user + RuntimeDirectory. Then drop THIS node's sim
    # ca/cert/key/config over the packaged defaults, made readable by the qp-nebula service
    # user and relabeled (qp_nebula_etc_t / qp_nebula_key_t) so the confined unit can read them.
    npush "$a" "$QPN_RPM" /tmp/qp-nebula.rpm
    nssh "$a" "dnf install -y --disablerepo='*' --nogpgcheck /tmp/qp-nebula.rpm"
    npush "$a" "$PKI/ca.crt" "$D_DIR/ca.crt"
    npush "$a" "$PKI/$n.crt" "$D_DIR/$n.crt"
    npush "$a" "$PKI/$n.key" "$D_DIR/$n.key"
    npush "$a" "$CFG/$n.yml" "$D_DIR/config.yml"
    [ -x "$BIN/qp-tput" ] && npush "$a" "$BIN/qp-tput" "$D_TPUT" || true
    nssh "$a" "chgrp qp-nebula $D_DIR/ca.crt $D_DIR/$n.crt $D_DIR/$n.key $D_DIR/config.yml; \
               chmod 0640 $D_DIR/$n.key; chmod 0644 $D_DIR/ca.crt $D_DIR/$n.crt $D_DIR/config.yml; \
               chmod 0755 $D_TPUT 2>/dev/null || true; \
               restorecon -RF $D_DIR"
  else
    nssh "$a" 'mkdir -p /opt/qpn'
    npush "$a" "$BIN/qp-nebula" /opt/qpn/qp-nebula
    npush "$a" "$PKI/ca.crt"    /opt/qpn/ca.crt
    npush "$a" "$PKI/$n.crt"    "/opt/qpn/$n.crt"
    npush "$a" "$PKI/$n.key"    "/opt/qpn/$n.key"
    npush "$a" "$CFG/$n.yml"    /opt/qpn/config.yml
    [ -x "$BIN/qp-tput" ] && npush "$a" "$BIN/qp-tput" /opt/qpn/qp-tput || true
  fi
  # Open the underlay handshake port (firewalld stays UP). Same in both modes.
  nssh "$a" "firewall-cmd -q --permanent --add-port=${PORT}/udp; firewall-cmd -q --add-port=${PORT}/udp" || true
  if [ "${LOSS:-0}" != 0 ] || [ "${DELAY:-0}" != 0 ]; then
    nssh "$a" "ifn=\$(ip -o -4 addr show | awk -v ip='${ULAY[$n]}' 'index(\$4,ip)==1{print \$2; exit}'); \
               tc qdisc replace dev \$ifn root netem loss ${LOSS:-0}% delay ${DELAY:-0}ms" || true
  fi
  if [ "$PROV" = rpm ]; then
    # Real deployment: enforcing, the packaged unit (init_t -> qp_nebula_t via the rpm's policy).
    nssh "$a" "setenforce 1; semanage permissive -d qp_nebula_t 2>/dev/null || true; systemctl start qp-nebula"
  else
    # Confine BEFORE starting: the daemon must exec from a labeled binary to land in
    # qp_nebula_t. systemd-run hands the exec to PID1 (init_t), so the transition fires.
    selinux_confine "$a" "$n"
    nssh "$a" "systemd-run --unit=qpn --collect /opt/qpn/qp-nebula -config /opt/qpn/config.yml" >/dev/null
  fi
  # Trust the overlay tun once nebula creates it, so overlay traffic (ICMP/app) is
  # delivered rather than dropped by firewalld's default zone.
  nssh "$a" "for i in \$(seq 1 20); do ip link show nebula1 >/dev/null 2>&1 && { firewall-cmd -q --zone=trusted --change-interface=nebula1; break; }; sleep 1; done" || true
  log "  $n daemon started ($PROV)"
}

# block_direct_underlay - for RELAY: each non-lighthouse node drops direct underlay UDP
# to the OTHER non-lighthouse nodes (lighthouses stay reachable), forcing traffic through
# a relay. The ruleset is built LOCALLY (with the discovered underlay addrs) and piped to
# the remote `nft` over ssh stdin - NOT a remote quoted heredoc (which would pass the
# unexpanded $(...) to nft).
block_direct_underlay(){
  local a b rules
  for a in "${!ROLE[@]}"; do [ "${ROLE[$a]}" = lighthouse ] && continue
    # Newline-separated nft ruleset (chain blocks must not share a line).
    rules=$'table inet qpn {\n  chain qpnout { type filter hook output priority 0; policy accept;\n'
    for b in "${!ROLE[@]}"; do [ "$b" = "$a" ] && continue; [ "${ROLE[$b]}" = lighthouse ] && continue
      rules+="    ip daddr ${ULAY[$b]} udp dport ${PORT} drop"$'\n'; done
    rules+=$'  }\n  chain qpnin { type filter hook input priority 0; policy accept;\n'
    for b in "${!ROLE[@]}"; do [ "$b" = "$a" ] && continue; [ "${ROLE[$b]}" = lighthouse ] && continue
      rules+="    ip saddr ${ULAY[$b]} udp sport ${PORT} drop"$'\n'; done
    rules+=$'  }\n}\n'
    printf '%s' "$rules" | nssh "${MGMT[$a]}" "nft -f -" || die "failed to install direct-block ruleset on $a"
  done
  log "direct node-to-node underlay UDP blocked (relay forced)"
}

in_set(){ local x="$1" s="$2" e; for e in $s; do [ "$e" = "$x" ] && return 0; done; return 1; }
intersect(){ local s1="$1" s2="$2" a b; for a in $s1; do for b in $s2; do [ "$a" = "$b" ] && return 0; done; done; return 1; }

# expected_reachable <a> <b> - is b reachable from a BY DESIGN, given roles + LH_SET?
# Models nebula discovery: a member reaches any lighthouse (lighthouses mesh) and any
# member that shares a lighthouse with it; a lighthouse reaches only its own clients +
# lighthouses it homes on. So a single-homed node is NOT reachable from a lighthouse it
# never registered with (e.g. lh2 -> n3 when n3 homes only lh1) - that is correct, not
# a failure, and must be excluded from the asserted matrix.
expected_reachable(){
  local a="$1" b="$2"
  if [ "${ROLE[$b]}" = lighthouse ]; then
    [ "${ROLE[$a]}" != lighthouse ] && return 0          # member -> any lighthouse (discovered)
    in_set "$b" "${LH_SET[$a]:-}"; return                # lighthouse -> lighthouse iff it homes on it
  fi
  if [ "${ROLE[$a]}" = lighthouse ]; then in_set "$a" "${LH_SET[$b]:-}"; return; fi   # lighthouse -> its client
  intersect "${LH_SET[$a]:-}" "${LH_SET[$b]:-}"          # member <-> member iff shared lighthouse
}

# assert_matrix [node ...] - overlay ping matrix among the named nodes (default: all),
# asserting ONLY pairs that are reachable by design (expected_reachable). Echoes the
# ok/total tally on stdout (safe to capture); FAIL lines to stderr; returns nonzero on
# any miss, so callers do: tally="$(assert_matrix)" || FAILED=1
assert_matrix(){
  local set=("$@"); [ ${#set[@]} -eq 0 ] && { local e; for e in "${NODES[@]}"; do set+=("${e%%:*}"); done; }
  local a b end ok=0 tot=0 miss=0 reached
  for a in "${set[@]}"; do for b in "${set[@]}"; do [ "$a" = "$b" ] && continue
    expected_reachable "$a" "$b" || continue
    tot=$((tot+1)); reached=0; end=$((SECONDS + ${DEADLINE:-60}))
    while [ "$SECONDS" -lt "$end" ]; do
      nssh "${MGMT[$a]}" "ping -c1 -W1 ${OVERLAY[$b]}" >/dev/null 2>&1 && { reached=1; break; }
      sleep 2
    done
    if [ "$reached" = 1 ]; then ok=$((ok+1)); else echo "  FAIL  $a -> $b (${OVERLAY[$b]})" >&2; miss=1; fi
  done; done
  echo "$ok/$tot"
  return $miss
}

# assert_pqix - confirm a lighthouse's journal shows pqIX (ML-KEM-1024) tunnels.
assert_pqix(){
  local entry n
  for entry in "${NODES[@]}"; do n="${entry%%:*}"
    [ "${ROLE[$n]}" = lighthouse ] || continue
    nssh "${MGMT[$n]}" "journalctl -u $D_UNIT --no-pager | grep -q 'style:pqix'" \
      && log "$n: tunnels are pqIX (ML-KEM-1024)" || { echo "  FAIL  $n: not pqIX"; FAILED=1; }
    return
  done
}

# setup_symmetric_nat <cidr...> - upgrade the per-node NAT masquerade to SYMMETRIC
# (random external port per flow) via iptables --random-fully, inserted ahead of
# libvirt's own masquerade. Best-effort: the double-NAT topology already forces relay
# (two nodes behind separate NATs have no inbound mapping for each other); this adds
# the true symmetric port-randomization. Paired with teardown_symmetric_nat.
setup_symmetric_nat(){
  local c
  for c in "$@"; do
    if sudo iptables -t nat -I LIBVIRT_PRT -s "$c" ! -d "$c" -j MASQUERADE --random-fully 2>/dev/null \
       || sudo iptables -t nat -I POSTROUTING -s "$c" ! -d "$c" -j MASQUERADE --random-fully 2>/dev/null; then
      log "symmetric NAT (random-fully) on $c"
    else
      log "WARN: could not apply random-fully for $c (double-NAT still forces relay)"
    fi
  done
}
teardown_symmetric_nat(){
  local c
  for c in "$@"; do
    sudo iptables -t nat -D LIBVIRT_PRT -s "$c" ! -d "$c" -j MASQUERADE --random-fully 2>/dev/null || true
    sudo iptables -t nat -D POSTROUTING -s "$c" ! -d "$c" -j MASQUERADE --random-fully 2>/dev/null || true
  done
}
