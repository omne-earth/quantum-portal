#!/usr/bin/env bash
# qp-ssh-keysign is the setuid helper used during HOST-BASED authentication.
# That path is not part of our opinionated defaults (we use pubkey auth), and the
# binary is root-only (0711) — so the happy-case here is: it loads + is invokable
# under sudo. Full host-based-auth coverage belongs in the VM clean-room.
TEST_NAME=qp-ssh-keysign
. "$(dirname "$0")/_common.sh"

ks="$LIBEXEC/${PFX}ssh-keysign"
sudo test -x "$ks" || fail "$ks not executable"
if out="$(printf '' | sudo timeout 5 "$ks" 2>&1)"; then rc=0; else rc=$?; fi
[ "$rc" != 127 ] || fail "ssh-keysign failed to load (rc 127): $out"
grep -qiE 'error while loading shared|cannot open shared object' <<<"$out" \
  && fail "ssh-keysign loader error: $out"
say "runs under sudo (rc=$rc); host-based auth not in defaults — full path is VM scope"
pass "ssh-keysign loads + is invokable (host-based-auth helper)"
