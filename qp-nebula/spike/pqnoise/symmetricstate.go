// Package pqnoise is the qp-nebula post-quantum handshake spike: a Noise-shaped
// key exchange built directly on ML-KEM-1024 (the "pqIX-analog"), because a KEM
// cannot be expressed through flynn/noise's DH-only DHFunc interface. See
// .notes/docs/DESIGN.md for the construction and .notes/docs/IMPLEMENTATION.md
// for the file-by-file plan this mirrors. Built hand-rolled, exactly as the sibling
// qp-stunnel/pqtls hand-builds ML-DSA X.509 certs that stdlib refuses to mint.
//
// symmetricstate.go is the Noise core: an HKDF-SHA384-chained key, a SHA-384
// transcript hash, and an AES-256-GCM AEAD keyed off the chain. It is a Noise
// *analog* (RFC 5869 HKDF, not Noise's bespoke byte-counter HKDF) and is NOT
// wire-compatible with any registered Noise protocol.
package pqnoise

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/sha512"
	"encoding/binary"
)

// protocolName is hashed into the initial transcript/chaining state. It pins the
// whole ciphersuite (pure ML-KEM-1024 KEX, AES-256-GCM AEAD, SHA-384/HKDF) so a
// peer running a different suite diverges immediately.
const protocolName = "pqIXanalog_MLKEM1024_AESGCM_SHA384"

// gcmTagSize is the AES-256-GCM authentication tag length appended by Seal.
const gcmTagSize = 16

// symmetricState mirrors Noise's SymmetricState. ck chains keys across MixKey,
// h binds the full transcript, k is the current AEAD key (valid once hasKey),
// and n is the per-key AEAD nonce counter (reset on every MixKey).
type symmetricState struct {
	ck     [48]byte
	h      [48]byte
	k      [32]byte
	hasKey bool
	n      uint64
}

func newSymmetricState() *symmetricState {
	sum := sha512.Sum384([]byte(protocolName))
	return &symmetricState{ck: sum, h: sum}
}

// mixHash folds data into the running transcript: h = SHA384(h || data).
func (s *symmetricState) mixHash(data []byte) {
	hh := sha512.New384()
	hh.Write(s.h[:])
	hh.Write(data)
	var out [48]byte
	hh.Sum(out[:0])
	s.h = out
}

// mixKey absorbs a fresh shared secret (a KEM output) into the chain and derives
// the next AEAD key: HKDF-Extract(salt=ck, ikm) -> Expand to 80 bytes -> (ck, k).
func (s *symmetricState) mixKey(ikm []byte) {
	prk, err := hkdf.Extract(sha512.New384, ikm, s.ck[:])
	if err != nil {
		panic(err) // sha384/HKDF over fixed-size inputs cannot fail in practice
	}
	out, err := hkdf.Expand(sha512.New384, prk, "", 80)
	if err != nil {
		panic(err)
	}
	copy(s.ck[:], out[:48])
	copy(s.k[:], out[48:])
	s.hasKey = true
	s.n = 0
}

// nonce is the Noise-convention 96-bit nonce: 4 zero bytes || 8-byte LE counter.
func nonce(n uint64) []byte {
	var nb [12]byte
	binary.LittleEndian.PutUint64(nb[4:], n)
	return nb[:]
}

func aead(key [32]byte) cipher.AEAD {
	block, err := aes.NewCipher(key[:])
	if err != nil {
		panic(err) // key is always 32 bytes
	}
	a, err := cipher.NewGCM(block)
	if err != nil {
		panic(err)
	}
	return a
}

// encryptAndHash encrypts pt under k (aad = current transcript h) when a key
// exists, otherwise passes it through in the clear (the msg1 case); either way
// the bytes-on-the-wire are folded into the transcript.
func (s *symmetricState) encryptAndHash(pt []byte) []byte {
	if !s.hasKey {
		s.mixHash(pt)
		return pt
	}
	ct := aead(s.k).Seal(nil, nonce(s.n), pt, s.h[:])
	s.n++
	s.mixHash(ct)
	return ct
}

// decryptAndHash is the inverse. The aad is the transcript h captured BEFORE this
// ciphertext is folded in (matching the peer's encryptAndHash ordering).
func (s *symmetricState) decryptAndHash(ct []byte) ([]byte, error) {
	if !s.hasKey {
		s.mixHash(ct)
		return ct, nil
	}
	aad := append([]byte(nil), s.h[:]...)
	pt, err := aead(s.k).Open(nil, nonce(s.n), ct, aad)
	if err != nil {
		return nil, err
	}
	s.n++
	s.mixHash(ct)
	return pt, nil
}

// split derives the two directional transport keys from the final chaining key:
// HKDF-Expand(HKDF-Extract(ck, "")) -> (k_i2r, k_r2i). Both peers run this on the
// same ck and so derive the identical pair.
func (s *symmetricState) split() (i2r, r2i *cipherState) {
	prk, err := hkdf.Extract(sha512.New384, []byte{}, s.ck[:])
	if err != nil {
		panic(err)
	}
	out, err := hkdf.Expand(sha512.New384, prk, "", 64)
	if err != nil {
		panic(err)
	}
	return newCipherState(out[:32]), newCipherState(out[32:])
}

// cipherState is one direction of the post-handshake transport: an AES-256-GCM
// context with its own monotonic nonce counter.
type cipherState struct {
	k [32]byte
	n uint64
}

func newCipherState(key []byte) *cipherState {
	cs := &cipherState{}
	copy(cs.k[:], key)
	return cs
}

// Encrypt seals pt with no associated data and advances the nonce.
func (c *cipherState) Encrypt(pt []byte) []byte {
	ct := aead(c.k).Seal(nil, nonce(c.n), pt, nil)
	c.n++
	return ct
}

// Decrypt opens ct and advances the nonce on success.
func (c *cipherState) Decrypt(ct []byte) ([]byte, error) {
	pt, err := aead(c.k).Open(nil, nonce(c.n), ct, nil)
	if err != nil {
		return nil, err
	}
	c.n++
	return pt, nil
}
