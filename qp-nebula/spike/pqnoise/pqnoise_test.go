// pqnoise_test.go is THE SPIKE: an in-memory exercise of the 3-message
// pqIX-analog handshake proving the load-bearing claims --
//
//   - both peers derive the identical chaining key and transport keys,
//   - an AEAD payload round-trips, and the transport round-trips both directions,
//   - an impostor static (a peer that does not hold the key it presents) and a
//     tampered ciphertext BOTH break key agreement / integrity.
//
// Deliberately out of scope (production handshake, not this spike): anti-replay,
// responder cookies / DoS defense, initiator identity hiding (S_i is cleartext,
// inherent to IX), session rekey, and any cert/CA binding -- the spike
// authenticates raw ML-KEM static keys. See .notes/docs/IMPLEMENTATION.md Sec 9.
package pqnoise

import (
	"bytes"
	"testing"

	"github.com/cloudflare/circl/kem/mlkem/mlkem1024"
)

// runHandshake drives a full I<->R exchange in memory and returns the two peers'
// final states plus the payload the responder recovered from msg3.
func runHandshake(t *testing.T, I, R *HandshakeState, payload []byte) (iI2R, iR2I, rI2R, rR2I *cipherState, recovered []byte) {
	t.Helper()
	m1, _, _, err := I.WriteMessage(nil)
	if err != nil {
		t.Fatalf("msg1 write: %v", err)
	}
	if _, _, _, err := R.ReadMessage(m1); err != nil {
		t.Fatalf("msg1 read: %v", err)
	}
	m2, _, _, err := R.WriteMessage(nil)
	if err != nil {
		t.Fatalf("msg2 write: %v", err)
	}
	if _, _, _, err := I.ReadMessage(m2); err != nil {
		t.Fatalf("msg2 read: %v", err)
	}
	m3, i2r, r2i, err := I.WriteMessage(payload)
	if err != nil {
		t.Fatalf("msg3 write: %v", err)
	}
	recovered, ri2r, rr2i, err := R.ReadMessage(m3)
	if err != nil {
		t.Fatalf("msg3 read: %v", err)
	}
	return i2r, r2i, ri2r, rr2i, recovered
}

func TestPQIXHandshake(t *testing.T) {
	sch := mlkem1024.Scheme()
	t.Logf("ML-KEM-1024 (circl): pub %dB, ct %dB, ss %dB",
		sch.PublicKeySize(), sch.CiphertextSize(), sch.SharedKeySize())

	iPub, iPriv, err := sch.GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	rPub, rPriv, err := sch.GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}

	I := NewInitiator(sch, iPub, iPriv)
	R := NewResponder(sch, rPub, rPriv)

	payload := []byte("QP_NEBULA_OK")
	iI2R, iR2I, rI2R, rR2I, got := runHandshake(t, I, R, payload)

	if !bytes.Equal(got, payload) {
		t.Fatalf("msg3 payload mismatch: %q != %q", got, payload)
	}
	if I.ss.ck != R.ss.ck {
		t.Fatal("chaining keys diverged: initiator ck != responder ck")
	}
	t.Logf("pqIX-analog: 3 messages; initiator ck == responder ck (%dB)", len(I.ss.ck))

	// Transport round-trips both directions. The initiator sends on i2r and
	// receives on r2i; the responder mirrors.
	ct := iI2R.Encrypt([]byte("ping"))
	if pt, err := rI2R.Decrypt(ct); err != nil || string(pt) != "ping" {
		t.Fatalf("i->r transport failed: pt=%q err=%v", pt, err)
	}
	ct = rR2I.Encrypt([]byte("pong"))
	if pt, err := iR2I.Decrypt(ct); err != nil || string(pt) != "pong" {
		t.Fatalf("r->i transport failed: pt=%q err=%v", pt, err)
	}
	t.Log("transport keys match; AEAD payload round-trips both directions")
}

// TestImpostorStaticFails: an initiator that presents a static public key it does
// not hold the private key for. The responder encapsulates to that key in msg2;
// the impostor decapsulates with the wrong key, diverges, and the encrypted S_r
// (and everything after) fails to open -- key agreement breaks, as it must.
func TestImpostorStaticFails(t *testing.T) {
	sch := mlkem1024.Scheme()
	aPub, _, err := sch.GenerateKeyPair() // a public key the impostor will present
	if err != nil {
		t.Fatal(err)
	}
	_, bPriv, err := sch.GenerateKeyPair() // ...but it only holds THIS unrelated private key
	if err != nil {
		t.Fatal(err)
	}
	rPub, rPriv, err := sch.GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}

	I := NewInitiator(sch, aPub, bPriv) // mismatched: pub of A, priv of B
	R := NewResponder(sch, rPub, rPriv)

	m1, _, _, err := I.WriteMessage(nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := R.ReadMessage(m1); err != nil {
		t.Fatal(err)
	}
	m2, _, _, err := R.WriteMessage(nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := I.ReadMessage(m2); err == nil {
		t.Fatal("expected msg2 read to FAIL for an impostor static, got nil")
	}
	t.Log("impostor static -> key agreement fails (expected)")
}

// TestTamperedCiphertextFails: flip a byte in msg3 and the responder's AEAD must
// reject it.
func TestTamperedCiphertextFails(t *testing.T) {
	sch := mlkem1024.Scheme()
	iPub, iPriv, _ := sch.GenerateKeyPair()
	rPub, rPriv, _ := sch.GenerateKeyPair()
	I := NewInitiator(sch, iPub, iPriv)
	R := NewResponder(sch, rPub, rPriv)

	m1, _, _, _ := I.WriteMessage(nil)
	R.ReadMessage(m1)
	m2, _, _, _ := R.WriteMessage(nil)
	I.ReadMessage(m2)
	m3, _, _, err := I.WriteMessage([]byte("QP_NEBULA_OK"))
	if err != nil {
		t.Fatal(err)
	}

	m3[len(m3)-1] ^= 0xff // corrupt the payload AEAD tag
	if _, _, _, err := R.ReadMessage(m3); err == nil {
		t.Fatal("expected tampered msg3 to FAIL AEAD, got nil")
	}
	t.Log("tampered ciphertext -> AEAD rejects (expected)")
}
