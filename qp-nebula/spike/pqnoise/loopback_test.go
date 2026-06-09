// loopback_test.go runs the pqIX-analog over a real 127.0.0.1 TCP socket with
// length-prefixed frames -- the Go analog of qp-stunnel's loopback smoke. The
// frame helpers (2-byte length prefix) are TEST SCAFFOLDING only; the production
// fork rides Nebula's existing UDP framing.
package pqnoise

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"testing"

	"github.com/cloudflare/circl/kem/mlkem/mlkem1024"
)

func writeFrame(c net.Conn, b []byte) error {
	var hdr [2]byte
	binary.BigEndian.PutUint16(hdr[:], uint16(len(b)))
	if _, err := c.Write(hdr[:]); err != nil {
		return err
	}
	_, err := c.Write(b)
	return err
}

func readFrame(c net.Conn) ([]byte, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(c, hdr[:]); err != nil {
		return nil, err
	}
	buf := make([]byte, binary.BigEndian.Uint16(hdr[:]))
	_, err := io.ReadFull(c, buf)
	return buf, err
}

const marker = "QP_NEBULA_OK"

func TestLoopback(t *testing.T) {
	sch := mlkem1024.Scheme()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	// Responder: accept, run the responder half, echo the marker back.
	done := make(chan error, 1)
	go func() {
		done <- func() error {
			conn, err := ln.Accept()
			if err != nil {
				return err
			}
			defer conn.Close()

			rPub, rPriv, err := sch.GenerateKeyPair()
			if err != nil {
				return err
			}
			R := NewResponder(sch, rPub, rPriv)

			m1, err := readFrame(conn)
			if err != nil {
				return err
			}
			if _, _, _, err := R.ReadMessage(m1); err != nil {
				return err
			}
			m2, _, _, err := R.WriteMessage(nil)
			if err != nil {
				return err
			}
			if err := writeFrame(conn, m2); err != nil {
				return err
			}
			m3, err := readFrame(conn)
			if err != nil {
				return err
			}
			_, i2r, r2i, err := R.ReadMessage(m3)
			if err != nil {
				return err
			}

			// Receive the initiator->responder marker, reply on the other key.
			ctIn, err := readFrame(conn)
			if err != nil {
				return err
			}
			got, err := i2r.Decrypt(ctIn)
			if err != nil {
				return err
			}
			if string(got) != marker {
				return fmt.Errorf("responder got %q, want %q", got, marker)
			}
			return writeFrame(conn, r2i.Encrypt([]byte(marker)))
		}()
	}()

	// Initiator: dial, run the initiator half, exchange the marker.
	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	iPub, iPriv, err := sch.GenerateKeyPair()
	if err != nil {
		t.Fatal(err)
	}
	I := NewInitiator(sch, iPub, iPriv)

	m1, _, _, err := I.WriteMessage(nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeFrame(conn, m1); err != nil {
		t.Fatal(err)
	}
	m2, err := readFrame(conn)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, err := I.ReadMessage(m2); err != nil {
		t.Fatal(err)
	}
	m3, i2r, r2i, err := I.WriteMessage([]byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	if err := writeFrame(conn, m3); err != nil {
		t.Fatal(err)
	}

	if err := writeFrame(conn, i2r.Encrypt([]byte(marker))); err != nil {
		t.Fatal(err)
	}
	rep, err := readFrame(conn)
	if err != nil {
		t.Fatal(err)
	}
	pt, err := r2i.Decrypt(rep)
	if err != nil {
		t.Fatal(err)
	}
	if string(pt) != marker {
		t.Fatalf("initiator got %q, want %q", pt, marker)
	}

	if err := <-done; err != nil {
		t.Fatalf("responder goroutine: %v", err)
	}
	t.Logf("loopback %s: handshake OK; %s round-tripped both directions", ln.Addr(), marker)
}
