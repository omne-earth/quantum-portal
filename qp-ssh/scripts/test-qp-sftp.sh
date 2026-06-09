#!/usr/bin/env bash
# User story: transfer files with qp-sftp (put + get) — exercises qp-sftp-server.
TEST_NAME=qp-sftp
. "$(dirname "$0")/_common.sh"

id="$(mint_authorized_key)"
printf 'qp-sftp-payload-%s\n' "$$" > "$WORK/src"
cat > "$WORK/batch" <<EOF
put $WORK/src $WORK/remote
get $WORK/remote $WORK/back
EOF
sftp="$(t sftp)"
"$sftp" -i "$id" -P "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o KexAlgorithms=mlkem1024-sha384 -b "$WORK/batch" "$SELF" \
        >"$WORK/out" 2>&1 || fail "sftp batch failed: $(cat "$WORK/out")"
cmp -s "$WORK/src" "$WORK/back" || fail "put/get round-trip mismatch"
pass "sftp put + get round-trip (via qp-sftp-server)"
