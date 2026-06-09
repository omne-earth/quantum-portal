#!/usr/bin/env python3
"""One-shot plaintext backend for the qp-stunnel loopback smoke.

Accepts a single TCP connection on 127.0.0.1:<port>, reads the request, replies
with <marker>\\n, and exits. This is the plaintext service qp-stunnel forwards
the decrypted TLS payload to — its reply proves the tunnel round-trips.

  usage: backend.py <port> <marker>
"""
import socket
import sys

port = int(sys.argv[1])
reply = (sys.argv[2] + "\n").encode()

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(1)
conn, _ = srv.accept()
conn.recv(65536)
conn.sendall(reply)
conn.close()
srv.close()
