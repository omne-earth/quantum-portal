#!/usr/bin/env bash
# qp-ssh-pkcs11-helper is spoken to by ssh/ssh-agent to drive a PKCS#11 token.
# With no token present there's no happy transfer path, so the happy-case is: it
# loads and exits cleanly when its pipe closes (EOF), as the agent would do.
# Full coverage needs a PKCS#11 token.
TEST_NAME=qp-ssh-pkcs11-helper
. "$(dirname "$0")/_common.sh"

h="$LIBEXEC/${PFX}ssh-pkcs11-helper"
[ -x "$h" ] || fail "$h not executable"
if out="$(printf '' | timeout 5 "$h" 2>&1)"; then rc=0; else rc=$?; fi
{ [ "$rc" != 127 ] && [ "$rc" != 124 ] && \
  ! grep -qiE 'error while loading shared|cannot open shared object' <<<"$out"; } \
  || fail "pkcs11-helper failed to load/run (rc=$rc): $out"
say "loads + exits on EOF (rc=$rc); full coverage needs a PKCS#11 token"
pass "ssh-pkcs11-helper loads + is invokable"
