#!/usr/bin/env bash
# qp-stunnel loopback smoke — the component acceptance test.
#
# Proves the load-bearing thing qp-stunnel does: a real, pure-post-quantum TLS 1.3
# connection (ML-KEM-1024 KEX + an ML-DSA-87 server cert) is TERMINATED by
# qp-stunnel and the decrypted plaintext is forwarded to a backend (and the
# backend's reply is encrypted back). Self-contained on loopback.
#
# Two legs, same algorithms throughout (ML-KEM-1024 KEX; ML-DSA-87 for every cert):
#   default   server-auth — the client verifies qp-stunnel's ML-DSA-87 server cert.
#   MTLS=1    mutual TLS   — also mints an ML-DSA-87 client CA + client cert and sets
#                           verify=2, so qp-stunnel requires + verifies the client too
#                           (the operator-only-trust posture the operator mesh runs).
#
# Deliberately out of scope (sim/integration, not the unit smoke): binding the real
# operator mesh interface (:9443 on the tun) and the EJBCA-issued chain (this mints
# throwaway self-signed certs).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # backend.py + stunnel.conf.in live here

STUNNEL="${STUNNEL:?set STUNNEL=path/to/the/built qp-stunnel binary}"
OPENSSL="${OPENSSL:-/usr/local/qp/bin/openssl}"   # the bundled, PQ-capable CLI
GROUP="${GROUP:-MLKEM1024}"
SIGALG="${SIGALG:-ML-DSA-87}"
APORT="${APORT:-19443}"   # TLS accept (loopback)
BPORT="${BPORT:-18080}"   # plaintext backend (loopback)
MARK="QP_STUNNEL_OK"
MTLS="${MTLS:-0}"         # 1 => mutual TLS: also mint + present a client cert (verify=2)
W="$(mktemp -d /tmp/qp-stunnel-smoke.XXXXXX)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$W"' EXIT

echo "[smoke] $("$STUNNEL" -version 2>&1 | grep -i 'Compiled/running' | sed 's/^ *//')"

# 1. Mint a throwaway self-signed ML-DSA-87 server cert (production uses EJBCA).
"$OPENSSL" genpkey -algorithm "$SIGALG" -out "$W/key.pem" 2>/dev/null
"$OPENSSL" req -x509 -key "$W/key.pem" -out "$W/cert.pem" -subj "/CN=qp-stunnel.mesh" -days 1 2>/dev/null
sig="$("$OPENSSL" x509 -in "$W/cert.pem" -noout -text | awk '/Signature Algorithm/{print $3; exit}')"
[ "$sig" = "$SIGALG" ] || { echo "[smoke] FAIL: cert sig is '$sig', not $SIGALG"; exit 1; }
echo "[smoke]   minted $sig cert"

# 1b. mTLS only: a client CA + a client cert chained to it — SAME ML-DSA-87 as the
#     server side, so the whole mutual handshake is one PQ signature algorithm.
if [ "$MTLS" = 1 ]; then
  "$OPENSSL" genpkey -algorithm "$SIGALG" -out "$W/ca-key.pem" 2>/dev/null
  "$OPENSSL" req -x509 -key "$W/ca-key.pem" -out "$W/client-ca.pem" -subj "/CN=qp-stunnel-mesh-ca" \
      -days 1 -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" 2>/dev/null
  "$OPENSSL" genpkey -algorithm "$SIGALG" -out "$W/client-key.pem" 2>/dev/null
  "$OPENSSL" req -new -key "$W/client-key.pem" -out "$W/client.csr" -subj "/CN=qp-mesh-client" 2>/dev/null
  "$OPENSSL" x509 -req -in "$W/client.csr" -CA "$W/client-ca.pem" -CAkey "$W/ca-key.pem" \
      -CAcreateserial -out "$W/client.pem" -days 1 2>/dev/null
  csig="$("$OPENSSL" x509 -in "$W/client.pem" -noout -text | awk '/Signature Algorithm/{print $3; exit}')"
  [ "$csig" = "$SIGALG" ] || { echo "[smoke] FAIL: client cert sig is '$csig', not $SIGALG"; exit 1; }
  echo "[smoke]   minted $csig client CA + client cert (mutual TLS)"
fi

# 2. One-shot plaintext backend that returns a marker (what stunnel forwards to).
#    Wait for it to bind before the client drives traffic — stunnel connects to it
#    lazily (per client connection), so a slow backend (e.g. python cold-start in the
#    toolbox) would otherwise race the client and get connection-refused.
python3 "$DIR/backend.py" "$BPORT" "$MARK" &
for _ in $(seq 1 40); do ss -H -tln 2>/dev/null | grep -q ":$BPORT " && break; sleep 0.1; done

# 3. qp-stunnel: TLS1.3, KEX group pinned to MLKEM1024, the ML-DSA-87 cert; accept -> backend.
#    Render the config template (no heredoc) — production config is in packaging/.
sed -e "s|@ACCEPT@|127.0.0.1:$APORT|"  -e "s|@CONNECT@|127.0.0.1:$BPORT|" \
    -e "s|@CERT@|$W/cert.pem|"         -e "s|@KEY@|$W/key.pem|" \
    -e "s|@CURVES@|$GROUP|"            "$DIR/stunnel.conf.in" > "$W/stunnel.conf"
# mTLS only: require + verify a client cert chained to the client CA (stunnel verify=2).
[ "$MTLS" = 1 ] && printf 'verify = 2\nCAfile = %s\n' "$W/client-ca.pem" >> "$W/stunnel.conf"
"$STUNNEL" "$W/stunnel.conf" >"$W/stunnel.log" 2>&1 &
for _ in $(seq 1 20); do ss -H -tln 2>/dev/null | grep -q ":$APORT " && break; sleep 0.25; done

# 4. Client: force the MLKEM1024 KEX, verify the ML-DSA-87 chain, read the forwarded marker.
#    Hold stdin ~1.5s so s_client reads the backend's reply before EOF closes it.
client_auth=()
[ "$MTLS" = 1 ] && client_auth=(-cert "$W/client.pem" -key "$W/client-key.pem")   # present the client cert
out="$( { printf 'PING\n'; sleep 1.5; } | "$OPENSSL" s_client -connect "127.0.0.1:$APORT" \
          -groups "$GROUP" -CAfile "$W/cert.pem" "${client_auth[@]}" -tls1_3 2>&1 || true )"
echo "[smoke]   $(grep -i 'Negotiated TLS1.3 group' <<<"$out" | head -1 | sed 's/^ *//')"
echo "[smoke]   $(grep -i 'Verify return code'      <<<"$out" | head -1 | sed 's/^ *//')"

fail() { echo "[smoke] FAIL: $1"; sed 's/^/    /' "$W/stunnel.log" 2>/dev/null | tail -10; exit 1; }
grep -qi "Negotiated TLS1.3 group: $GROUP" <<<"$out" || fail "KEX group is not $GROUP"
grep -qi 'Verify return code: 0'           <<<"$out" || fail "$SIGALG chain did not verify"
grep -q  "$MARK"                           <<<"$out" || fail "backend plaintext ($MARK) not forwarded back"

mode="server-auth"; [ "$MTLS" = 1 ] && mode="mutual TLS"
echo "[smoke] PASS ($mode): $GROUP KEX + $SIGALG cert terminated by qp-stunnel; plaintext forwarded"
