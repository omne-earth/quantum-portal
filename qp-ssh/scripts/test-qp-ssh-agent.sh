#!/usr/bin/env bash
# User story: start an auth agent, confirm it exposes a socket + pid, then stop it.
TEST_NAME=qp-ssh-agent
. "$(dirname "$0")/_common.sh"

ag="$(t ssh-agent)"
if ! eval "$("$ag" -s 2>/dev/null)" >/dev/null 2>&1; then fail "agent failed to start"; fi
[ -n "${SSH_AGENT_PID:-}" ] || fail "agent set no SSH_AGENT_PID"
trap 'kill "${SSH_AGENT_PID:-}" 2>/dev/null || true; _cleanup' EXIT
[ -S "${SSH_AUTH_SOCK:-/nonexistent}" ] || fail "agent exposed no socket"
say "pid $SSH_AGENT_PID, socket $SSH_AUTH_SOCK"
"$ag" -k >/dev/null 2>&1 || fail "agent failed to stop (-k)"
pass "agent start (socket + pid) then clean stop"
