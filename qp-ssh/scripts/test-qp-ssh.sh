#!/usr/bin/env bash
# User story: log in to the qp-sshd and run a command over the PQ channel.
TEST_NAME=qp-ssh
. "$(dirname "$0")/_common.sh"

id="$(mint_authorized_key)"
out="$("$(t ssh)" -i "$id" "${SSH_OPTS[@]}" "$SELF" 'echo QP_OK; id -un' 2>"$WORK/err")" || true
grep -q QP_OK <<<"$out" || fail "no QP_OK over mlkem1024/ssh-mldsa-87: $(cat "$WORK/err")"
say "remote ran as: $(tail -1 <<<"$out")"
pass "login + remote exec over the PQ channel"
