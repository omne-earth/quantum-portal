#!/usr/bin/env bash
# qp-nebula install-tier CLI smoke ON THE HOST - the self-contained acceptance test, the
# qp-nebula analog of qp-stunnel's test-pqtls.sh loopback smoke. In production the node
# cert/key are provisioned OUT OF BAND, so a bare install has none; here we mint a
# THROWAWAY CA + host cert and run an EPHEMERAL qp-nebula entirely in a temp dir (its own
# config, control socket, tun, on a spare loopback port) so `qp-nebula ctl` has a live
# socket to drive. It NEVER touches the installed unit or /usr/local/qp/etc - everything
# is killed + removed on exit. Unlike stunnel's userspace proxy, nebula needs a tun, so
# this needs root (self-elevates); otherwise it mirrors test-pqtls.sh.
#   QP_PREFIX=/usr/local/qp bash test-ctl-host.sh
set -uo pipefail

QP="${QP_PREFIX:-/usr/local/qp}"
NEB="$QP/sbin/qp-nebula"
CERT="$QP/bin/qp-nebula-cert"
TUN=nebsmoke0
PORT="${QPN_SMOKE_PORT:-14242}"

fail(){ echo "  FAIL: $*" >&2; exit 1; }
ok(){   echo "  OK: $*"; }

[ "$(id -u)" -eq 0 ] || exec sudo -E -- "$0" "$@"
[ -x "$NEB" ]  || fail "installed daemon missing: $NEB (install the rpm first)"
[ -x "$CERT" ] || fail "installed cert tool missing: $CERT"

# Self-contained in a temp dir (throwaway certs, config, control socket, log). Lastly UNWIRE
# everything on ANY exit: kill the ephemeral daemon, drop its (non-persistent) tun, delete
# the temp dir - exactly test-pqtls.sh's `kill $(jobs -p); rm -rf $W`, plus the tun nebula
# needs that stunnel does not.
W="$(mktemp -d /tmp/qp-nebula-cli.XXXXXX)"
SOCK="$W/ctl.sock"
cleanup(){
  kill $(jobs -p) 2>/dev/null || true
  ip link delete "$TUN" 2>/dev/null || true
  rm -rf "$W"
  echo "[test-ctl-host] unwired (daemon killed, tun removed, temp dir deleted)"
}
trap cleanup EXIT

echo "[test-ctl-host] minting a throwaway CA + host cert (temp)"
"$CERT" ca -name "qp-nebula install-smoke CA" -curve MLDSA87 -duration 24h \
  -out-crt "$W/ca.crt" -out-key "$W/ca.key" || fail "nebula-cert ca failed"
"$CERT" sign -ca-crt "$W/ca.crt" -ca-key "$W/ca.key" -duration 1h \
  -name "qp-nebula-host" -networks "10.255.255.1/24" \
  -out-crt "$W/host.crt" -out-key "$W/host.key" || fail "nebula-cert sign failed"

# Minimal self-sufficient config: a lighthouse-of-one (needs no peers), its own tun +
# control socket, underlay bound to loopback on a spare port (won't clash with an installed
# daemon on 4242). Run from a shell, so SELinux leaves it unconfined - no module/labels needed.
cat > "$W/config.yml" <<YAML
pki: {ca: $W/ca.crt, cert: $W/host.crt, key: $W/host.key}
static_host_map: {}
lighthouse: {am_lighthouse: true, hosts: []}
listen: {host: 127.0.0.1, port: $PORT}
tun: {dev: $TUN, mtu: 1300}
firewall: {outbound: [{port: any, proto: any, host: any}], inbound: [{port: any, proto: any, host: any}]}
control: {socket: $SOCK}
logging: {level: info}
YAML

echo "[test-ctl-host] starting an ephemeral qp-nebula (tun $TUN, socket $SOCK)"
"$NEB" -config "$W/config.yml" >"$W/nebula.log" 2>&1 &
for _ in $(seq 1 30); do
  [ -S "$SOCK" ] && break
  kill -0 %1 2>/dev/null || fail "daemon exited early: $(tail -1 "$W/nebula.log")"
  sleep 0.5
done
[ -S "$SOCK" ] || fail "control socket never appeared at $SOCK: $(tail -2 "$W/nebula.log")"
ok "ephemeral daemon up; socket $SOCK"

# ---- drive qp-nebula ctl against the live socket ------------------------------------
CTL="$NEB ctl -socket $SOCK"
out="$($CTL version 2>&1)" && ok "ctl version -> $(printf '%s' "$out" | head -1)" || fail "ctl version (got: $out)"
$CTL list-hostmap >/dev/null 2>&1            && ok "ctl list-hostmap"        || fail "ctl list-hostmap"
$CTL help 2>&1 | grep -q list-hostmap        && ok "ctl help lists commands" || fail "ctl help"
# negative: an unreachable socket must exit non-zero (the local connect gate)
if $NEB ctl -socket /run/nope.sock version >/dev/null 2>&1; then
  fail "ctl on a nonexistent socket exited 0"
else
  ok "ctl on a nonexistent socket exits non-zero"
fi

echo "[test-ctl-host] PASS"
