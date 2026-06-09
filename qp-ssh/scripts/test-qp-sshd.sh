#!/usr/bin/env bash
# User story: validate the opinionated server config + report the PQ build.
TEST_NAME=qp-sshd
. "$(dirname "$0")/_common.sh"

sshd="$SBIN/${PFX}sshd"
cfg="$ETC/${PFX}sshd_config"
# -t parses config + loads the (root-only) host keys; needs sudo.
sudo "$sshd" -t -f "$cfg" 2>"$WORK/err" || fail "config test (-t) failed: $(cat "$WORK/err")"
ver="$("$sshd" -V 2>&1 | head -1)"
grep -qi 'Open Quantum Safe' <<<"$ver" || fail "no OQS version banner: $ver"
say "$ver"
pass "qp-sshd_config valid (-t) + PQ version banner"
