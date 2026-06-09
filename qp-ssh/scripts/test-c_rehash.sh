#!/usr/bin/env bash
# User story: c_rehash builds the subject-hash symlinks for a cert directory.
TEST_NAME=c_rehash
. "$(dirname "$0")/_common.sh"

ossl="$BIN/openssl"; cr="$BIN/c_rehash"
# c_rehash is a generated perl wrapper around `openssl rehash` (shebang #!/usr/bin/env perl),
# not a compiled binary we vend. Without a perl interpreter it cannot run at all; the minimal
# VM image carries none, so skip rather than fail on a missing host dependency.
have perl || { say "no perl interpreter — c_rehash is a perl wrapper; skipping"; pass "skipped (perl unavailable)"; }
"$ossl" req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/k.pem" -out "$WORK/c.pem" \
        -days 1 -subj /CN=qp-rehash-test 2>/dev/null || fail "test cert generation failed"
mkdir -p "$WORK/certs"; cp "$WORK/c.pem" "$WORK/certs/"
OPENSSL="$ossl" "$cr" "$WORK/certs" >/dev/null 2>&1 || fail "c_rehash run failed"
ls "$WORK"/certs/*.0 >/dev/null 2>&1 || fail "c_rehash created no <hash>.0 symlink"
say "hash link: $(basename "$(ls "$WORK"/certs/*.0 | head -1)")"
pass "rehashed a cert directory (subject-hash symlink created)"
