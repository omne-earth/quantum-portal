#!/usr/bin/env bash
# qp-ssh-sk-helper is the FIDO/security-key middleware ssh uses for sk-* keys.
# With no authenticator attached there's no happy enrollment path, so the
# happy-case is: it loads and exits cleanly on EOF (as ssh would close its pipe).
# Full coverage needs a FIDO2 device.
TEST_NAME=qp-ssh-sk-helper
. "$(dirname "$0")/_common.sh"

h="$LIBEXEC/${PFX}ssh-sk-helper"
[ -x "$h" ] || fail "$h not executable"
if out="$(printf '' | timeout 5 "$h" 2>&1)"; then rc=0; else rc=$?; fi
{ [ "$rc" != 127 ] && [ "$rc" != 124 ] && \
  ! grep -qiE 'error while loading shared|cannot open shared object' <<<"$out"; } \
  || fail "sk-helper failed to load/run (rc=$rc): $out"
say "loads + exits on EOF (rc=$rc); full coverage needs a FIDO2 authenticator"
pass "ssh-sk-helper loads + is invokable"
