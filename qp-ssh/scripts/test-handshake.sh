#!/usr/bin/env bash
# qp-ssh loopback handshake smoke — the component acceptance test, toolbox-friendly.
#
# Proves the load-bearing thing qp-ssh does: a real post-quantum SSH handshake —
# mlkem1024-sha384 KEX with an ssh-mldsa-87 host key + ssh-mldsa-87 client pubkey auth —
# then runs a command over the channel. Self-contained: spawns its OWN qp-sshd as the
# invoking user on a high loopback port (OpenSSH regress-style), so it needs no install,
# no systemd, no privilege — it validates the freshly BUILT binaries in the toolbox.
#
# Driven by the Makefile's test-handshake target inside the toolbox, where the build
# tree is symlinked at $(QP_PREFIX) so the binaries' compiled-in absolute paths (RPATH,
# OpenSSL OPENSSLDIR, the qp-sshd-session libexec helper) all resolve. The installed,
# SELinux-confined, systemd-run deployment is validated separately in the VM tier.
set -euo pipefail

QP="${QP_PREFIX:-/usr/local/qp}"
PFX="${QP_PROGRAM_PREFIX:-qp-}"
PORT="${PORT:-12222}"               # loopback test port (NOT the production QP_PORT)
SSHD="$QP/sbin/${PFX}sshd"
SSH="$QP/bin/${PFX}ssh"
KG="$QP/bin/${PFX}ssh-keygen"
KEX="mlkem1024-sha384"
SIG="ssh-mldsa-87"
MARK="QP_SSH_OK"
W="$(mktemp -d /tmp/qp-ssh-smoke.XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$W"' EXIT

echo "[smoke] $("$SSH" -V 2>&1 | head -1)"

# 1. Host key + client identity, both ssh-mldsa-87 (the PQ signature algorithm).
rm -f "$W/host" "$W/host.pub" "$W/id" "$W/id.pub"   # never let keygen prompt to overwrite (hangs on non-interactive stdin)
"$KG" -t "$SIG" -f "$W/host" -N "" -q
"$KG" -t "$SIG" -f "$W/id"   -N "" -q
cp "$W/id.pub" "$W/authorized_keys"; chmod 600 "$W/authorized_keys"
echo "[smoke]   minted $SIG host key + client identity"

# 2. Minimal opinionated server config: PQ KEX + PQ signature only, loopback, our keys.
cat > "$W/sshd_config" <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $W/host
AuthorizedKeysFile $W/authorized_keys
PasswordAuthentication no
PubkeyAuthentication yes
StrictModes no
PidFile $W/sshd.pid
KexAlgorithms $KEX
PubkeyAcceptedAlgorithms $SIG
HostKeyAlgorithms $SIG
Subsystem sftp $QP/libexec/${PFX}sftp-server
CFG
"$SSHD" -t -f "$W/sshd_config" || { echo "[smoke] FAIL: sshd config rejected"; exit 1; }

# 3. Spawn the daemon on loopback; wait for the listening socket.
"$SSHD" -D -e -f "$W/sshd_config" >"$W/sshd.log" 2>&1 &
# Capture then grep — not `ss | grep -q`: a mid-stream match closes the pipe, SIGPIPEs ss,
# and pipefail flags the pipeline as failed despite the port being up (intermittent).
for _ in $(seq 1 50); do socks="$(ss -H -tln 2>/dev/null)"; grep -q ":$PORT " <<<"$socks" && break; sleep 0.1; done
socks="$(ss -H -tln 2>/dev/null)"
grep -q ":$PORT " <<<"$socks" \
  || { echo "[smoke] FAIL: qp-sshd not listening on :$PORT"; sed 's/^/    /' "$W/sshd.log"; exit 1; }
echo "[smoke]   qp-sshd listening on 127.0.0.1:$PORT"

# 4. Handshake: run a command over the channel; -v lets us assert the PQ KEX actually ran.
out="$("$SSH" -v -i "$W/id" -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes "$(id -un)@127.0.0.1" "echo $MARK" 2>"$W/cli.err")" || true

fail() {
  echo "[smoke] FAIL: $1"
  echo "--- client ---"; sed 's/^/    /' "$W/cli.err" | tail -20
  echo "--- sshd ---";   sed 's/^/    /' "$W/sshd.log" | tail -10
  exit 1
}
grep -q "kex: algorithm: $KEX" "$W/cli.err" || fail "negotiated KEX is not $KEX"
echo "[smoke]   KEX negotiated: $KEX"
[ "$out" = "$MARK" ] || fail "session command did not round-trip ($MARK)"
echo "[smoke] PASS: $KEX KEX + $SIG host/client auth; session ran '$MARK'"
