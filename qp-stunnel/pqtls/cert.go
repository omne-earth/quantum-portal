// ML-DSA-87 X.509 certificates, by hand. stdlib crypto/x509 refuses ML-DSA
// (only RSA/ECDSA/Ed25519), so qp-stunnel builds the RFC 5280 structure itself:
// CIRCL supplies the SPKI encoding + the algorithm OID, we supply the ASN.1 and
// the signature. Self-signed here for the spike; EJBCA issues the real chain.
package pqtls

import (
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/pem"
	"math/big"
	"time"

	"github.com/cloudflare/circl/pki"
	"github.com/cloudflare/circl/sign/mldsa/mldsa87"
)

// mldsa87OID is the FIPS-204 ML-DSA-87 algorithm OID, sourced from CIRCL so it
// can't drift from what pki.MarshalPKIXPublicKey stamps into the SPKI.
func mldsa87OID() asn1.ObjectIdentifier {
	return mldsa87.Scheme().(pki.CertificateScheme).Oid()
}

type validity struct{ NotBefore, NotAfter time.Time }

// tbsCertificateV1 is a v1 TBSCertificate (no version field, no extensions) —
// the minimal RFC 5280 body, enough to prove the algorithm round-trips.
type tbsCertificateV1 struct {
	SerialNumber *big.Int
	Signature    pkix.AlgorithmIdentifier
	Issuer       asn1.RawValue
	Validity     validity
	Subject      asn1.RawValue
	SPKI         asn1.RawValue
}

type certificate struct {
	TBS       asn1.RawValue
	Algorithm pkix.AlgorithmIdentifier
	Signature asn1.BitString
}

// MintMLDSACert builds a self-signed v1 X.509 certificate whose subject public
// key AND issuer signature are both ML-DSA-87. Returns DER + PEM.
func MintMLDSACert(cn string, pub *mldsa87.PublicKey, priv *mldsa87.PrivateKey) (der, pemBytes []byte, err error) {
	spki, err := pki.MarshalPKIXPublicKey(pub)
	if err != nil {
		return nil, nil, err
	}
	algID := pkix.AlgorithmIdentifier{Algorithm: mldsa87OID()}
	name, err := asn1.Marshal(pkix.Name{CommonName: cn}.ToRDNSequence())
	if err != nil {
		return nil, nil, err
	}

	tbs := tbsCertificateV1{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Signature:    algID,
		Issuer:       asn1.RawValue{FullBytes: name},
		Validity:     validity{time.Now().Add(-time.Minute).UTC(), time.Now().Add(24 * time.Hour).UTC()},
		Subject:      asn1.RawValue{FullBytes: name},
		SPKI:         asn1.RawValue{FullBytes: spki},
	}
	tbsDER, err := asn1.Marshal(tbs)
	if err != nil {
		return nil, nil, err
	}

	sig := make([]byte, mldsa87.SignatureSize)
	if err := mldsa87.SignTo(priv, tbsDER, nil, false, sig); err != nil {
		return nil, nil, err
	}

	der, err = asn1.Marshal(certificate{
		TBS:       asn1.RawValue{FullBytes: tbsDER},
		Algorithm: algID,
		Signature: asn1.BitString{Bytes: sig, BitLength: len(sig) * 8},
	})
	if err != nil {
		return nil, nil, err
	}
	return der, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), nil
}

// VerifyMLDSASelfSigned re-parses a cert from MintMLDSACert and checks the
// ML-DSA-87 signature over its TBSCertificate — the verify path stdlib also lacks.
func VerifyMLDSASelfSigned(der []byte, pub *mldsa87.PublicKey) (bool, error) {
	var c certificate
	if _, err := asn1.Unmarshal(der, &c); err != nil {
		return false, err
	}
	return mldsa87.Verify(pub, c.TBS.FullBytes, nil, c.Signature.Bytes), nil
}
