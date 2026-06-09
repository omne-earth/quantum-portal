// pqcert_test.go is THE PKI SPIKE: it proves an ML-DSA-87 CA can mint and verify a cert
// that carries an ML-KEM-1024 node key, that the embedded key is a usable handshake key,
// and that a wrong CA, a tampered cert, and an expired window all fail.
//
// Out of scope (the fork's job, not this proof): Nebula's actual cert wire format, cert
// chains / intermediate CAs, revocation, and binding to real mesh IPs. See
// .notes/docs/IMPLEMENTATION.md Sec 11.
package pqcert

import (
	"bytes"
	"testing"
	"time"

	"github.com/cloudflare/circl/kem/mlkem/mlkem1024"
	"github.com/cloudflare/circl/sign/mldsa/mldsa87"
)

func freshIdentity() Identity {
	now := time.Now().UTC().Truncate(time.Second)
	return Identity{
		Issuer:    "qp-nebula CA",
		Subject:   "node-1.mesh",
		Groups:    []string{"operators", "edge"},
		NotBefore: now.Add(-time.Minute),
		NotAfter:  now.Add(24 * time.Hour),
	}
}

func TestMintVerifyRoundTrip(t *testing.T) {
	caPub, caPriv, err := NewCAKey()
	if err != nil {
		t.Fatal(err)
	}
	nodePub, nodePriv, err := NewNodeKey()
	if err != nil {
		t.Fatal(err)
	}

	der, err := MintCert(caPriv, freshIdentity(), nodePub)
	if err != nil {
		t.Fatalf("mint: %v", err)
	}
	id, err := VerifyCert(der, caPub)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}

	if id.Subject != "node-1.mesh" || id.Issuer != "qp-nebula CA" {
		t.Fatalf("identity mismatch: %+v", id)
	}
	if len(id.Groups) != 2 || id.Groups[0] != "operators" || id.Groups[1] != "edge" {
		t.Fatalf("groups mismatch: %v", id.Groups)
	}
	t.Logf("ML-DSA-87 sig %dB; ML-KEM-1024 node key %dB; signed cert %dB",
		mldsa87.SignatureSize, len(id.KEMPublicKey), len(der))

	// The cert actually carries the node's real handshake key: encapsulate to the key
	// recovered from the verified cert, decapsulate with the node's private key, and the
	// shared secrets must match. This is what binds the PKI to the pqnoise handshake.
	sch := mlkem1024.Scheme()
	certKey, err := sch.UnmarshalBinaryPublicKey(id.KEMPublicKey)
	if err != nil {
		t.Fatalf("recover KEM key: %v", err)
	}
	ct, ssEnc, err := sch.Encapsulate(certKey)
	if err != nil {
		t.Fatal(err)
	}
	ssDec, err := sch.Decapsulate(nodePriv, ct)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(ssEnc, ssDec) {
		t.Fatal("cert KEM key does not match the node private key")
	}
	t.Log("cert binds a usable ML-KEM-1024 handshake key (encap/decap agree)")
}

// TestWrongCAFails: a cert minted by CA A must not verify under CA B's public key.
func TestWrongCAFails(t *testing.T) {
	_, caPrivA, _ := NewCAKey()
	caPubB, _, _ := NewCAKey()
	nodePub, _, _ := NewNodeKey()

	der, err := MintCert(caPrivA, freshIdentity(), nodePub)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyCert(der, caPubB); err == nil {
		t.Fatal("expected verify under the WRONG CA to fail, got nil")
	}
	t.Log("wrong CA -> verify fails (expected)")
}

// TestTamperedCertFails: flip a byte and the ML-DSA-87 signature must reject it.
func TestTamperedCertFails(t *testing.T) {
	caPub, caPriv, _ := NewCAKey()
	nodePub, _, _ := NewNodeKey()

	der, err := MintCert(caPriv, freshIdentity(), nodePub)
	if err != nil {
		t.Fatal(err)
	}
	der[len(der)/2] ^= 0xff // corrupt a byte inside the signed body
	if _, err := VerifyCert(der, caPub); err == nil {
		t.Fatal("expected tampered cert to fail verify, got nil")
	}
	t.Log("tampered cert -> verify fails (expected)")
}

// TestExpiredCertFails: a validity window in the past must be rejected even with a good
// signature.
func TestExpiredCertFails(t *testing.T) {
	caPub, caPriv, _ := NewCAKey()
	nodePub, _, _ := NewNodeKey()

	id := freshIdentity()
	past := time.Now().UTC().Truncate(time.Second).Add(-48 * time.Hour)
	id.NotBefore, id.NotAfter = past, past.Add(time.Hour)

	der, err := MintCert(caPriv, id, nodePub)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifyCert(der, caPub); err == nil {
		t.Fatal("expected expired cert to fail verify, got nil")
	}
	t.Log("expired window -> verify fails (expected)")
}
