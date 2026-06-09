#!/usr/bin/env bash
# qp-ssh vended-binary smoke — every built ELF must resolve its shared libs (the
# bundled openssl/liboqs via rpath — the exact class of bug that left qp-sshd unable to
# map libcrypto) AND execute. ldd proves resolution; a -V probe proves it runs (a
# usage/"unknown option" reply still means it ran — only a loader error, rc 127, or a
# hang is a failure). Covers client tools, the daemon, openssl, and the libexec helpers;
# the shell uninstall script (non-ELF) is skipped.
#
# Driven by the Makefile's test-binaries target inside the toolbox against the BUILT
# tree, symlinked at $(QP_PREFIX) so rpath/OPENSSLDIR resolve as installed. Env:
# QP_PREFIX, QP_PROGRAM_PREFIX.
set -euo pipefail

QP="${QP_PREFIX:-/usr/local/qp}"

echo "[smoke] all vended binaries load their libs + execute"
fail=0; n=0
for b in "$QP"/bin/* "$QP"/sbin/* "$QP"/libexec/*; do
  [ -f "$b" ] || continue
  name=$(basename "$b")
  [ -r "$b" ] || { echo "  skip ($name: root-only 0711 — setuid helper; covered by the VM tier under sudo)"; continue; }
  case "$(file -b "$b" 2>/dev/null)" in *ELF*) ;; *) echo "  skip (non-ELF): $name"; continue ;; esac
  n=$((n+1))
  miss=$(ldd "$b" 2>&1 | grep 'not found' || true)
  if [ -n "$miss" ]; then
    echo "  FAIL $name: unresolved libs"; printf '%s\n' "$miss" | sed 's/^/      /'; fail=1; continue
  fi
  # capture in an `if` so errexit doesn't abort when the probe exits non-zero
  # (a usage/"invalid command" reply is success — it ran).
  if out=$(timeout 10 "$b" -V </dev/null 2>&1); then rc=0; else rc=$?; fi
  if [ "$rc" -eq 127 ] || [ "$rc" -eq 124 ] || printf '%s' "$out" | grep -qiE 'error while loading shared|cannot open shared object'; then
    echo "  FAIL $name (rc=$rc): $(printf '%s' "$out" | head -1)"; fail=1; continue
  fi
  echo "  ok: $name"
done
[ "$n" -gt 0 ] || { echo "  no ELF binaries under $QP"; exit 1; }
[ "$fail" -eq 0 ] || { echo "[smoke] binary check FAILED"; exit 1; }
echo "[smoke] PASS: $n binaries verified"
