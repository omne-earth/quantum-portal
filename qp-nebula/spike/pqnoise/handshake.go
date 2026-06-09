// handshake.go drives the 3-message pqIX-analog over ML-KEM-1024:
//
//	msg1  I -> R :  e, s                 # E_i.pub (clear) ; S_i.pub (clear, no key yet)
//	msg2  R -> I :  e, ekem, skem, s     # E_r.pub ; encap->E_i (FS) ; encap->S_i (auth I) ; enc(S_r.pub)
//	msg3  I -> R :  skem, [payload]      # encap->S_r (auth R) ; AEAD payload ; both Split()
//
// A KEM token = the encapsulator names a target public key, does
// Encapsulate(target) -> (ct, ss), folds ct into the transcript and ss into the
// chain, and puts ct on the wire; the decapsulator reads ct, folds it in, and does
// Decapsulate(sk, ct) -> ss into the chain. Both stay in lock-step iff the
// decapsulator truly holds the private key the encapsulator targeted -- that "iff"
// is the whole authentication argument. Neither side pre-knows the other's static
// (the IX property): statics are learned in-band via the s tokens.
package pqnoise

import (
	"fmt"

	"github.com/cloudflare/circl/kem"
)

// HandshakeState carries one peer through the three flights. step is a shared
// counter advanced on every WriteMessage/ReadMessage call: an initiator runs
// Write(0), Read(1), Write(2); a responder runs Read(0), Write(1), Read(2).
type HandshakeState struct {
	ss        *symmetricState
	sch       kem.Scheme
	initiator bool
	step      int

	sPub  kem.PublicKey  // our static
	sPriv kem.PrivateKey
	ePub  kem.PublicKey // our ephemeral (minted in writeE)
	ePriv kem.PrivateKey

	rePub kem.PublicKey // peer ephemeral (learned in readE)
	rsPub kem.PublicKey // peer static (learned in readS)
}

func newHS(sch kem.Scheme, initiator bool, sPub kem.PublicKey, sPriv kem.PrivateKey) *HandshakeState {
	return &HandshakeState{ss: newSymmetricState(), sch: sch, initiator: initiator, sPub: sPub, sPriv: sPriv}
}

// NewInitiator / NewResponder build a handshake from this peer's own static
// keypair. The peer's static is NOT supplied -- it is transmitted and learned
// during the handshake (Nebula's in-band, CA-validated IX model).
func NewInitiator(sch kem.Scheme, sPub kem.PublicKey, sPriv kem.PrivateKey) *HandshakeState {
	return newHS(sch, true, sPub, sPriv)
}

func NewResponder(sch kem.Scheme, sPub kem.PublicKey, sPriv kem.PrivateKey) *HandshakeState {
	return newHS(sch, false, sPub, sPriv)
}

// --- token helpers --------------------------------------------------------

// writeE mints a fresh ephemeral, sends its public key in the clear, mixHashes it.
func (h *HandshakeState) writeE(out []byte) ([]byte, error) {
	pub, priv, err := h.sch.GenerateKeyPair()
	if err != nil {
		return nil, err
	}
	h.ePub, h.ePriv = pub, priv
	pb, err := pub.MarshalBinary()
	if err != nil {
		return nil, err
	}
	h.ss.mixHash(pb)
	return append(out, pb...), nil
}

// readE reads the peer ephemeral public key and mixHashes it.
func (h *HandshakeState) readE(in []byte) ([]byte, error) {
	n := h.sch.PublicKeySize()
	if len(in) < n {
		return nil, fmt.Errorf("readE: short message (%d < %d)", len(in), n)
	}
	pub, err := h.sch.UnmarshalBinaryPublicKey(in[:n])
	if err != nil {
		return nil, err
	}
	h.rePub = pub
	h.ss.mixHash(in[:n])
	return in[n:], nil
}

// writeS sends our static public key via EncryptAndHash -- cleartext in msg1
// (no key yet), encrypted in msg2 (after the ekem/skem MixKeys).
func (h *HandshakeState) writeS(out []byte) ([]byte, error) {
	pb, err := h.sPub.MarshalBinary()
	if err != nil {
		return nil, err
	}
	return append(out, h.ss.encryptAndHash(pb)...), nil
}

// readS reads the peer static public key. Its on-wire length depends on whether a
// key is active (AEAD tag present), which both peers agree on from the transcript.
func (h *HandshakeState) readS(in []byte) ([]byte, error) {
	n := h.sch.PublicKeySize()
	if h.ss.hasKey {
		n += gcmTagSize
	}
	if len(in) < n {
		return nil, fmt.Errorf("readS: short message (%d < %d)", len(in), n)
	}
	pb, err := h.ss.decryptAndHash(in[:n])
	if err != nil {
		return nil, err
	}
	pub, err := h.sch.UnmarshalBinaryPublicKey(pb)
	if err != nil {
		return nil, err
	}
	h.rsPub = pub
	return in[n:], nil
}

// writeKEM encapsulates to target, folds ct + ss into the state, emits ct.
func (h *HandshakeState) writeKEM(target kem.PublicKey, out []byte) ([]byte, error) {
	ct, ss, err := h.sch.Encapsulate(target)
	if err != nil {
		return nil, err
	}
	h.ss.mixHash(ct)
	h.ss.mixKey(ss)
	return append(out, ct...), nil
}

// readKEM reads a ciphertext, decapsulates with priv, folds ct + ss in.
func (h *HandshakeState) readKEM(priv kem.PrivateKey, in []byte) ([]byte, error) {
	n := h.sch.CiphertextSize()
	if len(in) < n {
		return nil, fmt.Errorf("readKEM: short message (%d < %d)", len(in), n)
	}
	ss, err := h.sch.Decapsulate(priv, in[:n])
	if err != nil {
		return nil, err
	}
	h.ss.mixHash(in[:n])
	h.ss.mixKey(ss)
	return in[n:], nil
}

// --- message driver -------------------------------------------------------

// WriteMessage produces this peer's next outbound flight, optionally carrying a
// payload (only the final flight does). On the final flight it also returns the
// two transport CipherStates (i2r, r2i); otherwise those are nil.
func (h *HandshakeState) WriteMessage(payload []byte) (msg []byte, i2r, r2i *cipherState, err error) {
	defer func() { h.step++ }()
	switch {
	case h.initiator && h.step == 0: // msg1: e, s
		if msg, err = h.writeE(nil); err != nil {
			return
		}
		msg, err = h.writeS(msg)
		return
	case h.initiator && h.step == 2: // msg3: skem (auth R), payload ; split
		if msg, err = h.writeKEM(h.rsPub, nil); err != nil {
			return
		}
		msg = append(msg, h.ss.encryptAndHash(payload)...)
		i2r, r2i = h.ss.split()
		return
	case !h.initiator && h.step == 1: // msg2: e, ekem (FS), skem (auth I), s
		if msg, err = h.writeE(nil); err != nil {
			return
		}
		if msg, err = h.writeKEM(h.rePub, msg); err != nil { // encap -> E_i
			return
		}
		if msg, err = h.writeKEM(h.rsPub, msg); err != nil { // encap -> S_i
			return
		}
		msg, err = h.writeS(msg)
		return
	}
	err = fmt.Errorf("WriteMessage: unexpected step %d (initiator=%v)", h.step, h.initiator)
	return
}

// ReadMessage consumes the peer's next flight. On the final flight it returns the
// decrypted payload and the two transport CipherStates; otherwise payload is the
// (empty) handshake payload and the cipher states are nil.
func (h *HandshakeState) ReadMessage(in []byte) (payload []byte, i2r, r2i *cipherState, err error) {
	defer func() { h.step++ }()
	switch {
	case !h.initiator && h.step == 0: // read msg1: e, s
		var rest []byte
		if rest, err = h.readE(in); err != nil {
			return
		}
		_, err = h.readS(rest)
		return
	case h.initiator && h.step == 1: // read msg2: e, ekem, skem, s
		var rest []byte
		if rest, err = h.readE(in); err != nil {
			return
		}
		if rest, err = h.readKEM(h.ePriv, rest); err != nil { // decap ekem with E_i
			return
		}
		if rest, err = h.readKEM(h.sPriv, rest); err != nil { // decap skem with S_i
			return
		}
		_, err = h.readS(rest)
		return
	case !h.initiator && h.step == 2: // read msg3: skem, payload ; split
		var rest []byte
		if rest, err = h.readKEM(h.sPriv, in); err != nil { // decap skem with S_r
			return
		}
		if payload, err = h.ss.decryptAndHash(rest); err != nil {
			return
		}
		i2r, r2i = h.ss.split()
		return
	}
	err = fmt.Errorf("ReadMessage: unexpected step %d (initiator=%v)", h.step, h.initiator)
	return
}
