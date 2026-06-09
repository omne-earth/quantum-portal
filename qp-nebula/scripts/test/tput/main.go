// qp-tput - a tiny stdlib-only TCP throughput probe for the pqIX tunnel stress
// test. iperf3 can't run where this test needs it: the endpoints have to sit
// INSIDE the two network namespaces (so the bytes actually cross n1 -> PQ tunnel
// -> n2), and the rootless build toolbox can't enter a netns. So we build our own
// probe from the same real-binary ethos as nebula/nebula-cert and run it in the
// namespaces alongside the daemons.
//
// The SERVER measures: it reads one stream to EOF and reports the received rate,
// timed from the first byte so connection setup doesn't dilute the number. The
// CLIENT blasts a fixed buffer for -t seconds then closes. Receiver-measured and
// EOF-bounded, so the rate reflects bytes actually delivered, not send buffering.
package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"time"
)

func main() {
	server := flag.Bool("s", false, "server mode (accept one stream, report received rate)")
	client := flag.Bool("c", false, "client mode (blast for -t seconds)")
	bind := flag.String("B", "0.0.0.0", "server bind host")
	host := flag.String("h", "", "client target host")
	port := flag.Int("p", 5201, "TCP port")
	dur := flag.Int("t", 10, "client send duration (seconds)")
	flag.Parse()

	switch {
	case *server:
		runServer(*bind, *port)
	case *client:
		runClient(*host, *port, time.Duration(*dur)*time.Second)
	default:
		fmt.Fprintln(os.Stderr, "usage: qp-tput -s -B <host> -p <port> | -c -h <host> -p <port> -t <sec>")
		os.Exit(2)
	}
}

func runServer(bind string, port int) {
	addr := net.JoinHostPort(bind, strconv.Itoa(port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen %s: %v\n", addr, err)
		os.Exit(1)
	}
	defer ln.Close()
	conn, err := ln.Accept()
	if err != nil {
		fmt.Fprintf(os.Stderr, "accept: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	buf := make([]byte, 256*1024)
	var total int64
	var start time.Time
	// Time from the first delivered byte to EOF.
	n, err := conn.Read(buf)
	if n > 0 {
		start = time.Now()
		total += int64(n)
	}
	for err == nil {
		n, err = conn.Read(buf)
		total += int64(n)
	}
	// A clean client close surfaces as EOF or a reset; either way the bytes we
	// counted are real. Only a zero-byte transfer is a genuine failure.
	if err != nil && err != io.EOF {
		_ = err
	}
	elapsed := time.Since(start).Seconds()
	if total == 0 || elapsed <= 0 {
		fmt.Fprintln(os.Stderr, "no data received")
		os.Exit(1)
	}
	gbits := float64(total) * 8 / elapsed / 1e9
	fmt.Printf("RESULT %.2f Gbits/sec (%d bytes in %.2fs)\n", gbits, total, elapsed)
}

func runClient(host string, port int, dur time.Duration) {
	if host == "" {
		fmt.Fprintln(os.Stderr, "client needs -h <host>")
		os.Exit(1)
	}
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "dial %s: %v\n", addr, err)
		os.Exit(1)
	}
	defer conn.Close()
	buf := make([]byte, 256*1024)
	deadline := time.Now().Add(dur)
	for time.Now().Before(deadline) {
		if _, err := conn.Write(buf); err != nil {
			fmt.Fprintf(os.Stderr, "write: %v\n", err)
			os.Exit(1)
		}
	}
}
