#!/usr/bin/env bash
# smoke/_common.sh — shared helpers for the per-tool user-story tests (test-*.sh).
#
# Sourced, not executed. These tests exercise how a user actually drives each
# vended binary against our opinionated PQ defaults (port 1716, mlkem1024-sha384
# KEX, ssh-mldsa-87 / ssh-falcon1024 keys). Daemon-spawned helpers are tested
# through the client op that invokes them; the path is asserted via the journal.
#
# Each test sets TEST_NAME, sources this, and ends pass/fail. Run via `make test`
# (Makefile.commons), which passes QP_PREFIX/QP_PORT/QP_PROGRAM_PREFIX.
set -euo pipefail

QP="${QP_PREFIX:-/usr/local/qp}"
PORT="${QP_PORT:-1716}"
PFX="${QP_PROGRAM_PREFIX:-qp-}"
BIN="$QP/bin"; SBIN="$QP/sbin"; LIBEXEC="$QP/libexec"; ETC="$QP/etc"

# tool path: t ssh -> /usr/local/qp/bin/qp-ssh
t()    { printf '%s' "$BIN/$PFX$1"; }
say()  { printf '    %s\n' "$*"; }
pass() { printf '    %s\n  PASS %s\n' "${1:-ok}" "${TEST_NAME:-$0}"; exit 0; }
fail() { printf '  FAIL %s: %s\n' "${TEST_NAME:-$0}" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# scratch dir, auto-cleaned; key stripped from authorized_keys if minted.
WORK="$(mktemp -d /tmp/qp-test.XXXXXX)"
# When we are root the loopback login lands as an unprivileged user (see below); the
# scp/sftp tests have that session write its remote files back into $WORK. mktemp gives
# 0700, so make $WORK sticky-world-writable (like /tmp) for those writes. Minted keys
# keep their own 0600 root ownership, so the login user still can't read them.
[ "$(id -u)" -eq 0 ] && chmod 1777 "$WORK"
_cleanup() {
  if [ -n "${_AUTH_PUB:-}" ] && [ -f "${_AUTH_AKF:-/dev/null}" ]; then
    grep -vF "$_AUTH_PUB" "$_AUTH_AKF" > "$_AUTH_AKF.t" 2>/dev/null || true
    mv "$_AUTH_AKF.t" "$_AUTH_AKF" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap _cleanup EXIT

# Login identity for the loopback connect. The deployment tier runs these as root
# against the INSTALLED daemon, but root's account is locked (`!` password) so qp-sshd
# refuses it ("User root not allowed because account is locked"). So when we are root we
# log in as a dedicated unprivileged user instead — created idempotently, mirroring the
# confine tier's qpconfine pattern. In the rootless toolbox we are already a normal user,
# so we log in as ourselves. The private key is minted in $WORK (readable by the client);
# only the authorized_keys lands in the login user's home.
if [ "$(id -u)" -eq 0 ]; then
  LOGIN_USER=qptest
  id "$LOGIN_USER" >/dev/null 2>&1 || useradd -m "$LOGIN_USER"
  LOGIN_HOME="$(getent passwd "$LOGIN_USER" | cut -d: -f6)"
else
  LOGIN_USER="$(id -un)"
  LOGIN_HOME="$HOME"
fi

# Mint a throwaway ML-DSA-87 identity and authorize it for the login user
# (AuthorizedKeysFile .qp-ssh/authorized_keys); prints the private-key path.
mint_authorized_key() {
  local id="$WORK/id"
  rm -f "$id" "$id.pub"   # if ever called twice, a stale key makes keygen prompt to overwrite (hangs on non-interactive stdin)
  "$(t ssh-keygen)" -t ssh-mldsa-87 -f "$id" -N "" -q
  local akf="$LOGIN_HOME/.qp-ssh/authorized_keys"
  install -d -m700 -o "$LOGIN_USER" -g "$LOGIN_USER" "$LOGIN_HOME/.qp-ssh"
  _AUTH_PUB="$(cat "$id.pub")"; _AUTH_AKF="$akf"
  printf '%s\n' "$_AUTH_PUB" >> "$akf"
  chown "$LOGIN_USER:$LOGIN_USER" "$akf"; chmod 600 "$akf"
  printf '%s' "$id"
}

# Non-interactive loopback connect bundle + target (array, available to sourcing
# scripts). Pin our PQ KEX/algos so the test fails loudly if defaults regress.
SELF="$LOGIN_USER@localhost"
SSH_OPTS=(-p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o BatchMode=yes -o KexAlgorithms=mlkem1024-sha384)

# Journal lines from qp-sshd since a marker time (for asserting helper spawns).
journal_since() { sudo journalctl -u qp-sshd.service --since "$1" --no-pager 2>/dev/null; }
now_stamp() { date '+%Y-%m-%d %H:%M:%S'; }
# Retry the journal read — entries can lag the connection by a beat.
wait_journal() {
  local stamp="$1" pat="$2" i
  # Capture then grep — not `journal_since | grep -q`: grep -q can match mid-stream and
  # close the pipe, SIGPIPE-ing journalctl, which pipefail then surfaces as a false miss.
  local j
  for i in $(seq 1 12); do j="$(journal_since "$stamp")"; grep -q "$pat" <<<"$j" && return 0; sleep 0.5; done
  return 1
}
