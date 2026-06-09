package pqtls

import (
	"crypto/rand"
	"crypto/x509"
	"testing"

	"github.com/cloudflare/circl/sign/mldsa/mldsa87"
)

// The cert half: we CAN mint + parse + verify a real ML-DSA-87 X.509 certificate
// by hand (CIRCL signs, we own the ASN.1) — and stdlib x509 still can't use it.
// This is the foundation qp-stunnel's TLS layer builds on; EJBCA issues the chain.
func TestMintMLDSACert_RoundTrips(t *testing.T) {
	pub, priv, err := mldsa87.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	der, pemBytes, err := MintMLDSACert("qp-stunnel.mesh", pub, priv)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("minted ML-DSA-87 X.509 cert: %d-byte DER, %d-byte PEM", len(der), len(pemBytes))

	ok, err := VerifyMLDSASelfSigned(der, pub)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("ML-DSA-87 signature over TBSCertificate failed to verify")
	}
	t.Log("round-trip OK: parsed + ML-DSA signature over the TBSCertificate verifies")

	// tamper check: a flipped TBS byte must break verification.
	bad := append([]byte(nil), der...)
	bad[len(bad)/2] ^= 0xff
	if ok, _ := VerifyMLDSASelfSigned(bad, pub); ok {
		t.Error("tampered cert still verified")
	}

	// the parse-side of the wall: stdlib x509 won't make a usable cert of it.
	if c, err := x509.ParseCertificate(der); err != nil {
		t.Logf("stdlib x509.ParseCertificate(ML-DSA) rejects it: %v", err)
	} else {
		t.Logf("stdlib parsed structurally but PublicKeyAlgorithm=%v (unusable for TLS auth)", c.PublicKeyAlgorithm)
	}
}
