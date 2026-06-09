#!/usr/bin/env bash
# User story: mint the opinionated PQ key types and verify them.
TEST_NAME=qp-ssh-keygen
. "$(dirname "$0")/_common.sh"

kg="$(t ssh-keygen)"
for algo in ssh-mldsa-87 ssh-falcon1024; do
  f="$WORK/$algo"; rm -f "$f" "$f.pub"   # never let keygen prompt to overwrite (hangs on non-interactive stdin)
  "$kg" -t "$algo" -f "$f" -N "" -q          || fail "generate $algo failed"
  [ -s "$f" ] && [ -s "$f.pub" ]             || fail "$algo key files missing/empty"
  "$kg" -y -f "$f" > "$WORK/$algo.re" 2>/dev/null || fail "re-derive pub (-y) failed for $algo"
  # the re-derived blob must match the generated .pub (type + base64 key fields)
  [ "$(cut -d' ' -f1-2 "$f.pub")" = "$(cut -d' ' -f1-2 "$WORK/$algo.re")" ] \
    || fail "$algo re-derived pubkey mismatch"
  fp="$("$kg" -l -f "$f.pub" 2>/dev/null)"   || fail "fingerprint (-l) failed for $algo"
  grep -q 'SHA256:' <<<"$fp"                 || fail "no SHA256 fingerprint for $algo: $fp"
  say "$algo -> $fp"
done
pass "minted + verified ssh-mldsa-87 and ssh-falcon1024"
