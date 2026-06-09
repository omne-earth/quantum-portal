#!/usr/bin/env bash
# User story: the per-connection session helper runs the user's command. Drive a
# login that executes a unique marker, and confirm qp-sshd-session logged it.
TEST_NAME=qp-sshd-session
. "$(dirname "$0")/_common.sh"

id="$(mint_authorized_key)"
marker="QP-SESSION-$$-${RANDOM}"
stamp="$(now_stamp)"; sleep 1
out="$("$(t ssh)" -i "$id" "${SSH_OPTS[@]}" "$SELF" "echo $marker" 2>/dev/null)" || true
grep -q "$marker" <<<"$out"                  || fail "session did not run the command"
wait_journal "$stamp" 'qp-sshd-session'      || fail "no qp-sshd-session in the journal"
pass "qp-sshd-session executed the remote command (logged)"
