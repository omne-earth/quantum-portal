// Package pqcert is the qp-nebula PQ-PKI proof: a minimal certificate that binds a
// node identity to its ML-KEM-1024 handshake key, signed by an ML-DSA-87 CA. It is
// the Phase-2 analog of the pqnoise spike -- it isolates the cert/identity layer (the
// "v3-analog Nebula cert" of .notes/docs/IMPLEMENTATION.md Sec 11) before the nebula
// fork, reusing the hand-built CIRCL approach of qp-stunnel/pqtls/cert.go but with one
// twist: the SUBJECT key is a KEM (ML-KEM-1024), not a signature key.
//
// This is NOT Nebula's wire cert format (protobuf v1 / ASN.1 v2). It proves the
// load-bearing crypto for the PKI: an ML-DSA-87 signature over a structure that carries
// an ML-KEM-1024 public key plus identity, with a sign/verify round-trip and the
// embedded key recovered as a usable handshake key. The bytes-on-the-wire format is the
// fork's job.
package pqcert

import (
	"crypto/rand"
	"crypto/x509/pkix"
	"encoding/asn1"
	"fmt"
	"math/big"
	"time"

	"github.com/cloudflare/circl/kem"
	"github.com/cloudflare/circl/kem/mlkem/mlkem1024"
	"github.com/cloudflare/circl/pki"
	"github.com/cloudflare/circl/sign/mldsa/mldsa87"
)

// mldsa87OID is the FIPS-204 ML-DSA-87 algorithm OID, sourced from CIRCL so it cannot
// drift from what the library actually signs/verifies with.
func mldsa87OID() asn1.ObjectIdentifier {
	return mldsa87.Scheme().(pki.CertificateScheme).Oid()
}

// Identity is the validated content of a cert: who the node is, when the binding is
// valid, and the ML-KEM-1024 public key the mesh runs the handshake against.
type Identity struct {
	Issuer       string
	Subject      string
	Groups       []string
	NotBefore    time.Time
	NotAfter     time.Time
	KEMPublicKey []byte // ML-KEM-1024 public key (MarshalBinary), 1568 bytes
}

// tbsCert is the to-be-signed body, ASN.1-encoded deterministically so signer and
// verifier agree on the exact bytes the CA signs over.
type tbsCert struct {
	SerialNumber *big.Int
	SigAlg       pkix.AlgorithmIdentifier // ML-DSA-87
	Issuer       string
	Subject      string
	NotBefore    time.Time
	NotAfter     time.Time
	Groups       []string
	KEMPublicKey []byte // the node's ML-KEM-1024 public key
}

// certificate is the signed wrapper: the exact TBS bytes + the CA's ML-DSA-87 signature.
type certificate struct {
	TBS       asn1.RawValue
	SigAlg    pkix.AlgorithmIdentifier
	Signature []byte
}

// NewCAKey generates an ML-DSA-87 CA signing keypair (the mesh trust anchor).
func NewCAKey() (*mldsa87.PublicKey, *mldsa87.PrivateKey, error) {
	return mldsa87.GenerateKey(rand.Reader)
}

// NewNodeKey generates an ML-KEM-1024 node keypair -- the static handshake key that a
// minted cert binds to an identity.
func NewNodeKey() (kem.PublicKey, kem.PrivateKey, error) {
	return mlkem1024.Scheme().GenerateKeyPair()
}

// MintCert builds and CA-signs a cert binding id (issuer/subject/groups/validity) to the
// node's ML-KEM-1024 public key. Returns the DER-encoded cert.
func MintCert(caPriv *mldsa87.PrivateKey, id Identity, nodeKEMPub kem.PublicKey) ([]byte, error) {
	kpb, err := nodeKEMPub.MarshalBinary()
	if err != nil {
		return nil, err
	}
	alg := pkix.AlgorithmIdentifier{Algorithm: mldsa87OID()}
	tbsDER, err := asn1.Marshal(tbsCert{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		SigAlg:       alg,
		Issuer:       id.Issuer,
		Subject:      id.Subject,
		NotBefore:    id.NotBefore.UTC(),
		NotAfter:     id.NotAfter.UTC(),
		Groups:       id.Groups,
		KEMPublicKey: kpb,
	})
	if err != nil {
		return nil, err
	}

	sig := make([]byte, mldsa87.SignatureSize)
	if err := mldsa87.SignTo(caPriv, tbsDER, nil, false, sig); err != nil {
		return nil, err
	}
	return asn1.Marshal(certificate{
		TBS:       asn1.RawValue{FullBytes: tbsDER},
		SigAlg:    alg,
		Signature: sig,
	})
}

// VerifyCert checks the CA's ML-DSA-87 signature over der, confirms the embedded key is
// a usable ML-KEM-1024 public key, and checks validity. It returns the bound Identity on
// success, or an error -- a wrong CA, a tampered cert, or an expired window all fail.
func VerifyCert(der []byte, caPub *mldsa87.PublicKey) (*Identity, error) {
	var c certificate
	if _, err := asn1.Unmarshal(der, &c); err != nil {
		return nil, fmt.Errorf("parse cert: %w", err)
	}
	if !mldsa87.Verify(caPub, c.TBS.FullBytes, nil, c.Signature) {
		return nil, fmt.Errorf("ML-DSA-87 signature does not verify (wrong CA or tampered cert)")
	}

	var tbs tbsCert
	if _, err := asn1.Unmarshal(c.TBS.FullBytes, &tbs); err != nil {
		return nil, fmt.Errorf("parse tbs: %w", err)
	}
	if _, err := mlkem1024.Scheme().UnmarshalBinaryPublicKey(tbs.KEMPublicKey); err != nil {
		return nil, fmt.Errorf("embedded KEM key is not a valid ML-KEM-1024 key: %w", err)
	}
	if now := time.Now(); now.Before(tbs.NotBefore) || now.After(tbs.NotAfter) {
		return nil, fmt.Errorf("cert not valid at %v (window %v..%v)", now, tbs.NotBefore, tbs.NotAfter)
	}

	return &Identity{
		Issuer:       tbs.Issuer,
		Subject:      tbs.Subject,
		Groups:       tbs.Groups,
		NotBefore:    tbs.NotBefore,
		NotAfter:     tbs.NotAfter,
		KEMPublicKey: tbs.KEMPublicKey,
	}, nil
}
