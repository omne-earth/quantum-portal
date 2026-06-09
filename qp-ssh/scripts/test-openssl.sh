#!/usr/bin/env bash
# User story: the bundled OpenSSL CLI runs against the bundled libcrypto and works.
TEST_NAME=openssl
. "$(dirname "$0")/_common.sh"

ossl="$BIN/openssl"
ver="$("$ossl" version 2>/dev/null)" || fail "openssl version failed"
grep -q '3\.6\.2' <<<"$ver" || fail "unexpected version (want bundled 3.6.2): $ver"
# Capture ldd, THEN grep the string — never `ldd | grep -q`. Under `set -o pipefail`
# grep -q matches the libcrypto line (mid-stream, ahead of libc/ld-linux), exits, and
# closes the pipe; ldd keeps writing, takes SIGPIPE (141), and pipefail then reports the
# whole pipeline as failed despite the match — an intermittent false negative.
links="$(ldd "$ossl" 2>/dev/null)"
grep -q "$QP/lib/libcrypto" <<<"$links" || fail "openssl not linked to bundled libcrypto"
"$ossl" rand -hex 16 >/dev/null 2>&1 || fail "openssl rand failed"
printf 'qp\n' | "$ossl" dgst -sha256 >/dev/null 2>&1 || fail "openssl dgst failed"
say "$ver (bundled libcrypto)"
pass "version + rand + dgst on the bundled OpenSSL"
