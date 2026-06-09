#!/usr/bin/env bash
# User story: the auth phase accepts an authorized PQ key and rejects an
# unauthorized one (the gate qp-sshd-auth enforces during preauth).
TEST_NAME=qp-sshd-auth
. "$(dirname "$0")/_common.sh"

ssh="$(t ssh)"; kg="$(t ssh-keygen)"

# authorized identity -> accepted
id="$(mint_authorized_key)"
stamp="$(now_stamp)"; sleep 1
"$ssh" -i "$id" "${SSH_OPTS[@]}" "$SELF" true 2>/dev/null || fail "authorized PQ key was rejected"
wait_journal "$stamp" 'Accepted publickey'   || fail "no 'Accepted publickey' in the journal"

# unauthorized identity -> rejected
rm -f "$WORK/bad" "$WORK/bad.pub"   # never let keygen prompt to overwrite (hangs on non-interactive stdin)
"$kg" -t ssh-mldsa-87 -f "$WORK/bad" -N "" -q
if "$ssh" -i "$WORK/bad" "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$SELF" true 2>/dev/null; then
  fail "an UNauthorized key was accepted — auth gate is broken"
fi
pass "accepts the authorized PQ key, rejects an unauthorized one"
