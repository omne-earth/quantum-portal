#!/usr/bin/env bash
# User story: copy a file to the host and back with qp-scp. Modern scp speaks the
# SFTP protocol, so this also drives qp-sftp-server.
TEST_NAME=qp-scp
. "$(dirname "$0")/_common.sh"

id="$(mint_authorized_key)"
opts=(-i "$id" -P "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes -o KexAlgorithms=mlkem1024-sha384)
printf 'qp-scp-payload-%s\n' "$$" > "$WORK/src"
scp="$(t scp)"
"$scp" "${opts[@]}" "$WORK/src" "$SELF:$WORK/dst"  2>"$WORK/err" || fail "scp upload failed: $(cat "$WORK/err")"
"$scp" "${opts[@]}" "$SELF:$WORK/dst" "$WORK/back" 2>"$WORK/err" || fail "scp download failed: $(cat "$WORK/err")"
cmp -s "$WORK/src" "$WORK/back" || fail "round-trip mismatch"
pass "file round-trip (up + down) over the PQ channel"
