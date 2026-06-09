#!/usr/bin/env bash
# Spike: prove pure-PQ TLS — ML-KEM-1024 KEX + an ML-DSA-87 server cert —
# handshakes end-to-end via OpenSSL 3.5+, natively (no oqs-provider, no fork, no
# CIRCL/liboqs in the TLS path). This is qp-stunnel's TLS engine.
#
# Uses whatever `openssl` resolves to here (system 3.5.5 is enough); qp-ssh
# bundles OpenSSL 3.6.2 with the same native PQ, which is the production engine.
#   OPENSSL=/usr/local/qp/bin/openssl ./openssl-pqtls.sh   # against the bundled one
set -euo pipefail

OPENSSL="${OPENSSL:-openssl}"
GROUP="${GROUP:-MLKEM1024}"
SIGALG="${SIGALG:-ML-DSA-87}"
PORT="${PORT:-14433}"
WORK="$(mktemp -d)"
SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "[spike] $("$OPENSSL" version)"

echo "[spike] mint self-signed $SIGALG cert (the only key + sig in the chain is PQ)"
"$OPENSSL" genpkey -algorithm "$SIGALG" -out "$WORK/key.pem" 2>/dev/null
"$OPENSSL" req -x509 -key "$WORK/key.pem" -out "$WORK/cert.pem" \
  -subj "/CN=qp-stunnel.mesh" -days 1 2>/dev/null
echo "[spike]   cert sig: $("$OPENSSL" x509 -in "$WORK/cert.pem" -noout -text | awk '/Signature Algorithm/{print $3; exit}')"

echo "[spike] s_server: $SIGALG cert, group restricted to $GROUP, TLS1.3 only"
"$OPENSSL" s_server -accept "$PORT" -cert "$WORK/cert.pem" -key "$WORK/key.pem" \
  -groups "$GROUP" -tls1_3 -www -quiet >"$WORK/srv.log" 2>&1 &
SRV=$!
sleep 1

echo "[spike] s_client: force group=$GROUP, verify the $SIGALG chain"
out="$(echo Q | "$OPENSSL" s_client -connect "127.0.0.1:$PORT" -groups "$GROUP" \
        -CAfile "$WORK/cert.pem" -tls1_3 2>&1 || true)"

grp="$(grep -i 'Negotiated TLS1.3 group' <<<"$out" | head -1 | sed 's/^ *//')"
vfy="$(grep -i 'Verify return code' <<<"$out" | head -1 | sed 's/^ *//')"
echo "[spike]   $grp"
echo "[spike]   $vfy"

grep -qi "Negotiated TLS1.3 group: $GROUP" <<<"$out" \
  || { echo "[spike] FAIL: KEX group is not $GROUP"; printf '%s\n' "$out" | tail -15; exit 1; }
grep -qi 'Verify return code: 0' <<<"$out" \
  || { echo "[spike] FAIL: $SIGALG chain did not verify"; exit 1; }

echo "[spike] PASS: $GROUP KEX + $SIGALG cert, handshake complete + verified"
