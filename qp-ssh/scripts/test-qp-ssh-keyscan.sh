#!/usr/bin/env bash
# User story: scrape the daemon's PQ host key with qp-ssh-keyscan.
TEST_NAME=qp-ssh-keyscan
. "$(dirname "$0")/_common.sh"

ks="$(t ssh-keyscan)"
out="$("$ks" -p "$PORT" -t ssh-mldsa-87 localhost 2>/dev/null)" || true
# fall back to an untyped scan if -t filtering isn't honored
grep -q 'ssh-mldsa-87' <<<"$out" || out="$("$ks" -p "$PORT" localhost 2>/dev/null)" || true
grep -q 'ssh-mldsa-87' <<<"$out" || fail "no ssh-mldsa-87 host key scanned from :$PORT: $out"
say "$(grep 'ssh-mldsa-87' <<<"$out" | head -1 | cut -c1-60)…"
pass "scraped the ML-DSA-87 host key from :$PORT"
