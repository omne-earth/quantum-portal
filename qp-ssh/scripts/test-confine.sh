#!/usr/bin/env bash
# qp-ssh deployment-tier smoke — the checks that need a REAL installed, systemd-run,
# SELinux-enforcing system, which a rootless toolbox cannot provide:
#   * qp-sshd is listening + the client runs,
#   * a login session transitions OUT of qp_sshd_t into the user's domain,
#   * the unit's CapabilityBoundingSet drops CAP_SYS_ADMIN,
#   * the qp-sshd-auth preauth helper carries the qp_sshd_auth_exec_t entrypoint,
#   * a full PQ handshake raises zero AVC denials.
# Ported verbatim from the inline smoke-alive/context/caps/preauth/avc Makefile recipes
# so the in-VM tier and the host tier assert the same things. Driven by the component's
# test-confine target inside a libvirt VM (simulation/scripts/runner.sh), run
# as root against the qp-ssh rpm installed there.
# Env: QP_PREFIX QP_PORT QP_PROGRAM_PREFIX (defaults match the rpm layout).
set -uo pipefail

QP="${QP_PREFIX:-/usr/local/qp}"
PORT="${QP_PORT:-1716}"
PFX="${QP_PROGRAM_PREFIX:-qp-}"
SSHBIN="$QP/bin/${PFX}ssh"
KG="$QP/bin/${PFX}ssh-keygen"

fail(){ echo "  FAIL: $*" >&2; exit 1; }
ok(){   echo "  OK: $*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
selinux_on(){ have selinuxenabled && selinuxenabled; }

# Unprivileged login user: the confined session must land in a USER domain, not the
# daemon domain, so we log in as a normal user (not root). Created idempotently.
U=qpconfine
id "$U" >/dev/null 2>&1 || useradd -m "$U"
UH="$(getent passwd "$U" | cut -d: -f6)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Mint a throwaway ML-DSA-87 identity and authorize it for $U (AuthorizedKeysFile
# .qp-ssh/authorized_keys). The key is generated as root then installed into $U's own dir
# so the `sudo -u $U` client can read it. Echoes the private-key path.
mint(){
  rm -f "$TMP/id" "$TMP/id.pub"   # mint is called more than once; a stale key makes keygen prompt to overwrite (hangs on the non-interactive stdin)
  "$KG" -t ssh-mldsa-87 -f "$TMP/id" -N "" -q
  install -d -m700 -o "$U" -g "$U" "$UH/.qp-ssh"
  install -m600 -o "$U" -g "$U" "$TMP/id"     "$UH/.qp-ssh/id"
  install -m600 -o "$U" -g "$U" "$TMP/id.pub" "$UH/.qp-ssh/authorized_keys"
  printf '%s' "$UH/.qp-ssh/id"
}
# Run a command over a loopback PQ login as $U (pin our KEX so a default regression fails
# loudly). $1=priv key, $2=remote command.
login(){
  sudo -u "$U" "$SSHBIN" -i "$1" -p "$PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -o KexAlgorithms=mlkem1024-sha384 "$U@localhost" "$2"
}

echo "[test-confine] qp-sshd listening on :$PORT + client runs"
# Capture then grep — not `ss | grep -q`: a mid-stream match closes the pipe, SIGPIPEs ss,
# and pipefail reports the pipeline failed despite the port being present (false negative).
socks="$(ss -H -tln 2>/dev/null)"
grep -q ":$PORT " <<<"$socks" || fail "qp-sshd not listening on $PORT"
"$SSHBIN" -V 2>&1 | sed 's/^/  /'
ok "listening on $PORT"

echo "[test-confine] login session lands in the user's domain, not qp_sshd_t"
if selinux_on; then
  id="$(mint)"; ctx="$(login "$id" 'id -Z')" || true
  [ -n "$ctx" ] || fail "no SELinux context returned from the login"
  dom="$(printf '%s' "$ctx" | cut -d: -f3)"
  [ "$dom" != qp_sshd_t ] || fail "session stuck in qp_sshd_t (policy transition missing)"
  ok "transitioned out of qp_sshd_t -> $dom"
else echo "  SELinux not enabled — skipped"; fi

echo "[test-confine] qp-sshd CapabilityBoundingSet excludes CAP_SYS_ADMIN"
pid="$(systemctl show -p MainPID --value qp-sshd 2>/dev/null)"
[ -n "$pid" ] && [ "$pid" != 0 ] || fail "qp-sshd not running (MainPID=$pid)"
bnd="$(awk '/^CapBnd:/{print $2}' /proc/"$pid"/status 2>/dev/null)"
[ -n "$bnd" ] || fail "could not read CapBnd for pid $pid"
[ $(( 0x$bnd & 0x200000 )) -eq 0 ] || fail "CAP_SYS_ADMIN present in CapBnd=0x$bnd"
ok "CapBnd=0x$bnd — CAP_SYS_ADMIN cleared"

echo "[test-confine] qp-sshd-auth is the entrypoint into the isolated preauth domain"
if selinux_on; then
  lbl="$(ls -Z "$QP/libexec/${PFX}sshd-auth" 2>/dev/null | awk '{print $1}')"
  case "$lbl" in
    *:qp_sshd_auth_exec_t:*) ok "preauth helper -> qp_sshd_auth_exec_t -> qp_sshd_net_t" ;;
    *) fail "expected qp_sshd_auth_exec_t (got '${lbl:-<none>}') — preauth isolation not wired" ;;
  esac
else echo "  SELinux not enabled — skipped"; fi

echo "[test-confine] a full PQ handshake produces zero qp-sshd SELinux denials"
if selinux_on && have ausearch; then
  id="$(mint)"; mark="$(date '+%H:%M:%S')"
  login "$id" true >/dev/null 2>&1 || true
  sleep 1
  # --input-logs: read the configured audit logs, NOT stdin. Under the non-interactive
  # ssh session stdin is a pipe, and ausearch defaults to reading stdin then (hangs).
  avc="$(ausearch --input-logs -m AVC -ts "$mark" 2>/dev/null | grep -E 'qp_sshd_t|qp_sshd_net_t|qp_sshd_auth_exec_t' || true)"
  if [ -n "$avc" ]; then
    printf '%s\n' "$avc" | grep -oE 'denied[^}]*}|comm="[^"]*"|scontext=[^ ]*|tcontext=[^ ]*|tclass=[^ ]*' | sed 's/^/    /'
    fail "SELinux denials during the handshake"
  fi
  ok "zero qp-sshd denials — monitor (qp_sshd_t) + preauth (qp_sshd_net_t) clean"
else echo "  SELinux/ausearch unavailable — skipped"; fi

echo "[test-confine] PASS"
