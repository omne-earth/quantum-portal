// Package pqtls is the qp-stunnel post-quantum TLS foundation: ML-KEM-1024 key
// exchange + ML-DSA-87 certificates, via CIRCL
//
// These tests ARE the spike. They assert what stdlib gives us for free, what
// CIRCL adds, and exactly where Go's fixed crypto/tls + crypto/x509 algorithm
// tables wall off pure-PQ certificates — i.e. precisely what the qp-stunnel TLS
// layer must itself supply (a CIRCL-aware tls/x509, not stdlib alone).
//
//	go test -v ./pqtls
package pqtls

import (
	"bytes"
	"crypto"
	"crypto/mlkem"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"io"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/cloudflare/circl/pki"
	"github.com/cloudflare/circl/sign/mldsa/mldsa87"
)

// stdlib already does the ML-KEM key exchange (Go 1.24+ crypto/mlkem). The KEX
// half of qp-stunnel's PQ-TLS is free.
func TestStdlib_MLKEM1024_KEX(t *testing.T) {
	dk, err := mlkem.GenerateKey1024()
	if err != nil {
		t.Fatal(err)
	}
	shared1, ct := dk.EncapsulationKey().Encapsulate()
	shared2, err := dk.Decapsulate(ct)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(shared1, shared2) {
		t.Fatal("ML-KEM-1024 shared secrets differ")
	}
	t.Logf("ML-KEM-1024 KEX (stdlib): %d-byte shared key, %d-byte ciphertext", len(shared1), len(ct))
}

// CIRCL does the ML-DSA-87 signatures. stdlib has NO ML-DSA at all.
func TestCircl_MLDSA87_SignVerify(t *testing.T) {
	pub, priv, err := mldsa87.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	msg := []byte("qp-stunnel pq-tls spike")
	sig := make([]byte, mldsa87.SignatureSize)
	if err := mldsa87.SignTo(priv, msg, nil, false, sig); err != nil {
		t.Fatal(err)
	}
	if !mldsa87.Verify(pub, msg, nil, sig) {
		t.Fatal("ML-DSA-87 verify failed")
	}
	t.Logf("ML-DSA-87 (CIRCL): %d-byte pub, %d-byte sig", mldsa87.PublicKeySize, len(sig))
}

// CIRCL gets ML-DSA-87 X.509-ready but NOT TLS-ready, and that gap is the spike's
// core finding: the scheme carries an X.509 OID (so certs are buildable/verifiable
// via CIRCL) but NO TLS SignatureScheme code point — so qp-stunnel's TLS layer must
// define the ML-DSA-87 TLS code point itself (per the TLS-ML-DSA drafts). This
// test is a tracking assertion: it trips if a future CIRCL starts handing us one.
func TestCircl_MLDSA87_X509ReadyButNotTLSReady(t *testing.T) {
	pub, _, err := mldsa87.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki, err := pki.MarshalPKIXPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("ML-DSA-87 SPKI (CIRCL pki): %d bytes", len(spki))

	sch := mldsa87.Scheme()
	cs, ok := sch.(pki.CertificateScheme)
	if !ok {
		t.Fatal("ML-DSA-87 lacks a pki.CertificateScheme OID — certs unreachable via CIRCL")
	}
	t.Logf("X.509-ready: OID %v (cert build/verify via CIRCL)", cs.Oid())

	if _, ok := sch.(pki.TLSScheme); ok {
		t.Error("CIRCL now exposes a TLS id for ML-DSA-87 — revisit the qp-stunnel TLS code-point plan")
	}
	t.Log("NOT TLS-ready: CIRCL assigns no TLS SignatureScheme id — qp-stunnel defines it")
}

// THE WALL. stdlib crypto/x509 has a fixed algorithm table with no ML-DSA, so it
// cannot build (or verify) an ML-DSA certificate even when handed a working
// CIRCL signer. This is the boundary qp-stunnel's TLS layer must cross — by wiring
// CIRCL's scheme into a tls/x509 that consult it (a cf-go-style fork or our own
// shim), NOT by stdlib alone.
func TestWall_StdlibX509_RejectsMLDSA(t *testing.T) {
	pub, priv, _ := mldsa87.GenerateKey(rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "qp-stunnel"},
		NotBefore:    time.Now(),
		NotAfter:     time.Now().Add(time.Hour),
	}
	signer := mldsaSigner{pub: pub, priv: priv}
	_, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, signer.Public(), signer)
	if err == nil {
		t.Fatal("expected stdlib x509 to reject ML-DSA, but it built a cert")
	}
	t.Logf("stdlib x509.CreateCertificate(ML-DSA) walled off: %v", err)
	if !strings.Contains(err.Error(), "RSA, ECDSA and Ed25519") {
		t.Logf("note: wall wording changed (still walled): %v", err)
	}
}

// mldsaSigner adapts CIRCL ML-DSA to crypto.Signer, so the rejection above is
// provably about the ALGORITHM, not a missing Signer.
type mldsaSigner struct {
	pub  *mldsa87.PublicKey
	priv *mldsa87.PrivateKey
}

func (s mldsaSigner) Public() crypto.PublicKey { return s.pub }

func (s mldsaSigner) Sign(_ io.Reader, msg []byte, _ crypto.SignerOpts) ([]byte, error) {
	sig := make([]byte, mldsa87.SignatureSize)
	if err := mldsa87.SignTo(s.priv, msg, nil, false, sig); err != nil {
		return nil, err
	}
	return sig, nil
}
