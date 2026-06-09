// Package interop is the third qp-nebula spike: it proves that circl (qp-nebula's pure-Go
// crypto) is WIRE-COMPATIBLE with qp-ssh's bundled OpenSSL on the two shared post-quantum
// primitives -- ML-KEM-1024 (FIPS 203) and ML-DSA-87 (FIPS 204).
//
// Why it matters: qp-nebula is the ONLY circl component; every other piece of the suite
// (qp-ssh, qp-stunnel) runs on the OpenSSL installed at /usr/local/qp/bin. If circl and
// that OpenSSL did not produce interoperable keys/ciphertexts/signatures, qp-nebula could
// not share the mesh PKI -- a CA cert minted by the OpenSSL side would not verify in
// qp-nebula, and ML-KEM keys could not be exchanged.
//
// The matrix (each direction, each primitive):
//   - ML-KEM-1024: OpenSSL encapsulates to a circl key -> circl decapsulates;  and reverse.
//   - ML-DSA-87:   circl signs -> OpenSSL verifies;                            and reverse.
//
// Requires qp-ssh installed. Skips cleanly (does not fail) when the openssl binary is
// absent, so the rest of `make smoke` still runs on machines without qp-ssh. Override the
// path with QP_OPENSSL.
package interop

import (
	"bytes"
	"crypto/rand"
	"encoding/asn1"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/cloudflare/circl/kem/mlkem/mlkem1024"
	"github.com/cloudflare/circl/sign/mldsa/mldsa87"
)

// FIPS algorithm OIDs (NIST CSOR arc), as the installed OpenSSL reports them.
var (
	oidMLKEM1024 = asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 4, 3}
	oidMLDSA87   = asn1.ObjectIdentifier{2, 16, 840, 1, 101, 3, 4, 3, 19}
)

func opensslPath(t *testing.T) string {
	t.Helper()
	p := os.Getenv("QP_OPENSSL")
	if p == "" {
		p = "/usr/local/qp/bin/openssl"
	}
	if _, err := os.Stat(p); err != nil {
		t.Skipf("qp-ssh openssl not found at %s (set QP_OPENSSL) - skipping interop", p)
	}
	return p
}

func mustRun(t *testing.T, bin string, args ...string) []byte {
	t.Helper()
	out, err := exec.Command(bin, args...).CombinedOutput()
	if err != nil {
		t.Fatalf("openssl %v failed: %v\n%s", args, err, out)
	}
	return out
}

// spki ASN.1: SubjectPublicKeyInfo { AlgorithmIdentifier{OID, no params}, BIT STRING raw }.
// For ML-KEM / ML-DSA the BIT STRING carries the raw FIPS key bytes directly, so this is
// exactly the encoding OpenSSL emits and accepts -- the thing under test.
type algID struct{ Algorithm asn1.ObjectIdentifier }
type spki struct {
	Algorithm algID
	PublicKey asn1.BitString
}

func spkiPEM(t *testing.T, oid asn1.ObjectIdentifier, raw []byte) []byte {
	t.Helper()
	der, err := asn1.Marshal(spki{algID{oid}, asn1.BitString{Bytes: raw, BitLength: len(raw) * 8}})
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})
}

func parseSPKI(t *testing.T, der []byte) (asn1.ObjectIdentifier, []byte) {
	t.Helper()
	var s spki
	if _, err := asn1.Unmarshal(der, &s); err != nil {
		t.Fatalf("parse SPKI: %v", err)
	}
	return s.Algorithm.Algorithm, s.PublicKey.Bytes
}

func write(t *testing.T, path string, b []byte) string {
	t.Helper()
	if err := os.WriteFile(path, b, 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// --- ML-KEM-1024 -----------------------------------------------------------

// OpenSSL encapsulates to a circl-generated ML-KEM key; circl decapsulates. Proves
// OpenSSL imports circl's public key and the KEM math agrees.
func TestMLKEM_OpenSSLEncap_CirclDecap(t *testing.T) {
	bin := opensslPath(t)
	dir := t.TempDir()
	sch := mlkem1024.Scheme()

	pub, priv, err := sch.GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	raw, err := pub.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	pubPath := write(t, filepath.Join(dir, "circl.pub.pem"), spkiPEM(t, oidMLKEM1024, raw))

	ctPath := filepath.Join(dir, "ct.bin")
	ssPath := filepath.Join(dir, "ss_ossl.bin")
	mustRun(t, bin, "pkeyutl", "-encap", "-inkey", pubPath, "-pubin", "-secret", ssPath, "-out", ctPath)

	ct, _ := os.ReadFile(ctPath)
	ssOssl, _ := os.ReadFile(ssPath)
	ssCircl, err := sch.Decapsulate(priv, ct)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(ssOssl, ssCircl) {
		t.Fatalf("ML-KEM secrets differ (OpenSSL encap -> circl decap): %x != %x", ssOssl, ssCircl)
	}
	t.Logf("ML-KEM-1024: OpenSSL encapsulated to a circl key, circl decapsulated, secrets agree (%dB)", len(ssCircl))
}

// circl encapsulates to an OpenSSL-generated ML-KEM key; OpenSSL decapsulates. Proves
// circl imports OpenSSL's public key.
func TestMLKEM_CirclEncap_OpenSSLDecap(t *testing.T) {
	bin := opensslPath(t)
	dir := t.TempDir()
	sch := mlkem1024.Scheme()

	keyPath := filepath.Join(dir, "ossl.key")
	mustRun(t, bin, "genpkey", "-algorithm", "ML-KEM-1024", "-out", keyPath)
	pubDERPath := filepath.Join(dir, "ossl.pub.der")
	mustRun(t, bin, "pkey", "-in", keyPath, "-pubout", "-outform", "DER", "-out", pubDERPath)

	pubDER, _ := os.ReadFile(pubDERPath)
	oid, rawKey := parseSPKI(t, pubDER)
	if !oid.Equal(oidMLKEM1024) {
		t.Fatalf("unexpected OID %v", oid)
	}
	pub, err := sch.UnmarshalBinaryPublicKey(rawKey)
	if err != nil {
		t.Fatalf("circl could not parse OpenSSL ML-KEM key: %v", err)
	}

	ct, ssCircl, err := sch.Encapsulate(pub)
	if err != nil {
		t.Fatal(err)
	}
	ctPath := write(t, filepath.Join(dir, "ct.bin"), ct)
	ssPath := filepath.Join(dir, "ss_ossl.bin")
	mustRun(t, bin, "pkeyutl", "-decap", "-inkey", keyPath, "-in", ctPath, "-secret", ssPath)

	ssOssl, _ := os.ReadFile(ssPath)
	if !bytes.Equal(ssCircl, ssOssl) {
		t.Fatalf("ML-KEM secrets differ (circl encap -> OpenSSL decap): %x != %x", ssCircl, ssOssl)
	}
	t.Log("ML-KEM-1024: circl encapsulated to an OpenSSL key, OpenSSL decapsulated, secrets agree")
}

// --- ML-DSA-87 -------------------------------------------------------------

// circl signs; OpenSSL verifies. Proves OpenSSL accepts circl's public key + signature.
func TestMLDSA_CirclSign_OpenSSLVerify(t *testing.T) {
	bin := opensslPath(t)
	dir := t.TempDir()

	pub, priv, err := mldsa87.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := pub.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	pubPath := write(t, filepath.Join(dir, "circl.pub.pem"), spkiPEM(t, oidMLDSA87, raw))

	msg := []byte("qp-nebula <-> qp-ssh ML-DSA-87 interop")
	msgPath := write(t, filepath.Join(dir, "msg.bin"), msg)
	sig := make([]byte, mldsa87.SignatureSize)
	if err := mldsa87.SignTo(priv, msg, nil, false, sig); err != nil {
		t.Fatal(err)
	}
	sigPath := write(t, filepath.Join(dir, "sig.bin"), sig)

	out := mustRun(t, bin, "pkeyutl", "-verify", "-inkey", pubPath, "-pubin", "-rawin", "-in", msgPath, "-sigfile", sigPath)
	t.Logf("ML-DSA-87: circl signed, OpenSSL verified (%s)", bytes.TrimSpace(out))
}

// OpenSSL signs; circl verifies. Proves circl accepts OpenSSL's public key + signature.
func TestMLDSA_OpenSSLSign_CirclVerify(t *testing.T) {
	bin := opensslPath(t)
	dir := t.TempDir()

	keyPath := filepath.Join(dir, "ossl.key")
	mustRun(t, bin, "genpkey", "-algorithm", "ML-DSA-87", "-out", keyPath)
	pubDERPath := filepath.Join(dir, "ossl.pub.der")
	mustRun(t, bin, "pkey", "-in", keyPath, "-pubout", "-outform", "DER", "-out", pubDERPath)

	pubDER, _ := os.ReadFile(pubDERPath)
	oid, rawKey := parseSPKI(t, pubDER)
	if !oid.Equal(oidMLDSA87) {
		t.Fatalf("unexpected OID %v", oid)
	}
	var pub mldsa87.PublicKey
	if err := pub.UnmarshalBinary(rawKey); err != nil {
		t.Fatalf("circl could not parse OpenSSL ML-DSA key: %v", err)
	}

	msg := []byte("qp-ssh -> qp-nebula ML-DSA-87 interop")
	msgPath := write(t, filepath.Join(dir, "msg.bin"), msg)
	sigPath := filepath.Join(dir, "sig.bin")
	mustRun(t, bin, "pkeyutl", "-sign", "-inkey", keyPath, "-rawin", "-in", msgPath, "-out", sigPath)

	sig, _ := os.ReadFile(sigPath)
	if !mldsa87.Verify(&pub, msg, nil, sig) {
		t.Fatal("circl FAILED to verify an OpenSSL-produced ML-DSA-87 signature")
	}
	t.Log("ML-DSA-87: OpenSSL signed, circl verified")
}
