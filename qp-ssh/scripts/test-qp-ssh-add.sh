#!/usr/bin/env bash
# User story: load a PQ identity into the agent and list it back.
TEST_NAME=qp-ssh-add
. "$(dirname "$0")/_common.sh"

ag="$(t ssh-agent)"; add="$(t ssh-add)"; kg="$(t ssh-keygen)"
if ! eval "$("$ag" -s 2>/dev/null)" >/dev/null 2>&1; then fail "could not start an agent for the test"; fi
trap 'kill "${SSH_AGENT_PID:-}" 2>/dev/null || true; _cleanup' EXIT

rm -f "$WORK/aid" "$WORK/aid.pub"   # never let keygen prompt to overwrite (hangs on non-interactive stdin)
"$kg" -t ssh-mldsa-87 -f "$WORK/aid" -N "" -q
"$add" "$WORK/aid" 2>/dev/null      || fail "ssh-add failed to add the key"
"$add" -l 2>/dev/null | grep -q 'SHA256:' || fail "ssh-add -l listed no key"
say "$("$add" -l 2>/dev/null | head -1)"
pass "added ML-DSA-87 identity to the agent and listed it"
