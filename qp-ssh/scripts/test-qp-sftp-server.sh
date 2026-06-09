#!/usr/bin/env bash
# User story: the daemon's SFTP subsystem. Drive it directly with the SFTP
# protocol — SSH_FXP_INIT(v3) must elicit SSH_FXP_VERSION (type 2).
TEST_NAME=qp-sftp-server
. "$(dirname "$0")/_common.sh"

srv="$LIBEXEC/${PFX}sftp-server"
[ -x "$srv" ] || fail "$srv not executable"
# it's wired as the daemon's sftp subsystem (informational)
if grep -qE "Subsystem[[:space:]]+sftp[[:space:]]+$srv" "$ETC/${PFX}sshd_config" 2>/dev/null; then
  say "wired as: Subsystem sftp $srv"
fi
# byte 4 of the reply is the packet type; 0x02 == SSH_FXP_VERSION. Hold stdin
# open briefly so the server flushes its reply before it sees EOF and exits.
typ="$({ printf '\x00\x00\x00\x05\x01\x00\x00\x00\x03'; sleep 1; } | timeout 5 "$srv" 2>/dev/null \
        | dd bs=1 skip=4 count=1 2>/dev/null | od -An -tx1 | tr -d ' ')" || true
[ "$typ" = "02" ] || fail "no SSH_FXP_VERSION reply to INIT (got type '0x$typ')"
pass "SFTP INIT -> VERSION handshake on the sftp subsystem"
