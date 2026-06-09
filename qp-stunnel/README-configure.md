# Configuring qp-stunnel

The rpm ships a working binary, a confined SELinux domain, and a
`%config(noreplace)` `qp-stunnel.conf` — but the service is installed
**enabled-not-started**. It stays down until you provision its TLS material and
point it at the mesh + backend, because none of that can ship in a package: the
certificate and key are node-specific and secret.

This doc covers the cert / CA material — **what each one is, where it lives, and
who sets it**. There are three distinct "CA certs" in this stack; only the first
two are runtime, and they are set the same way (provisioned out of band, never by
us). The third is build-time only.

---

## TL;DR — what you must provide

| Artifact | Path | Required? |
|---|---|---|
| Server cert (ML-DSA-87 leaf) | `/usr/local/qp/etc/qp-stunnel.crt` | always |
| Server private key | `/usr/local/qp/etc/qp-stunnel.key` | always |
| mTLS client CA | `/usr/local/qp/etc/qp-stunnel-ca.crt` | only for `verify = 2` |
| `accept` address + `connect` backend | in `qp-stunnel.conf` | always |

Then label, and start:

```sh
sudo restorecon -F /usr/local/qp/etc/qp-stunnel.{crt,key}
sudo semanage port -a -t qp_stunnel_backend_port_t -p tcp <backend-port>
sudo systemctl start qp-stunnel
```

---

## 1. Server identity — the cert qp-stunnel presents (always required)

Set in `qp-stunnel.conf`:

```ini
cert = /usr/local/qp/etc/qp-stunnel.crt
key  = /usr/local/qp/etc/qp-stunnel.key
```

This is an **EJBCA-issued ML-DSA-87 leaf certificate + its private key**,
provisioned out of band. It is
**deliberately not in the rpm** — the same way qp-ssh's host keys are not
packaged. qp-stunnel will not start without it.

Provisioning drops the two files in and fixes ownership + label:

```sh
# (files written by provisioning) -> /usr/local/qp/etc/qp-stunnel.{crt,key}
sudo chown qp-stunnel:qp-stunnel /usr/local/qp/etc/qp-stunnel.{crt,key}
sudo chmod 0640 /usr/local/qp/etc/qp-stunnel.key      # key: owner+group read only
sudo restorecon -F /usr/local/qp/etc/qp-stunnel.{crt,key}
```

`restorecon` applies the `.fc` rule that labels both `qp_stunnel_cert_t`, the
tight type only `qp_stunnel_t` can read — so even another confined daemon on the
host cannot read the private key.

---

## 2. mTLS client CA — the operator-only mesh trust anchor (optional)

The mesh is operator-only-trust, so the intended posture is **mutual TLS**: every
client also presents a certificate, verified against a CA. This is **commented off
by default** in `qp-stunnel.conf` (it needs the CA provisioned first):

```ini
verify = 2
CAfile = /usr/local/qp/etc/qp-stunnel-ca.crt
```

`verify = 2` requires *and* verifies a client cert chained to `CAfile`. The CA is
EJBCA-issued and provisioned out of band, exactly like the server cert — and the
shipped `.fc` labels `qp-stunnel-ca.crt` `qp_stunnel_cert_t`, so `qp_stunnel_t`
reads it the same way. Provision it, label it, then enable mTLS:

```sh
# (CA written by provisioning) -> /usr/local/qp/etc/qp-stunnel-ca.crt
sudo chown qp-stunnel:qp-stunnel /usr/local/qp/etc/qp-stunnel-ca.crt
sudo restorecon -F /usr/local/qp/etc/qp-stunnel-ca.crt   # -> qp_stunnel_cert_t
# uncomment verify/CAfile in qp-stunnel.conf, then:
sudo systemctl restart qp-stunnel
```

This mutual-TLS path is validated **enforcing** — a full ML-KEM-1024 + ML-DSA-87
handshake with a client cert chained to the CA, terminated by `qp_stunnel_t` with
zero SELinux denials.

---

## 3. Registry transport CA — build/release only, not runtime

This one has nothing to do with the TLS qp-stunnel terminates — it is how `make
publish` / `make link` trust the git host over HTTPS. Set declaratively
in `.env`:

```make
CA_CERT := $(CURDIR)/certs/your-git-ca.pem
```

and fed to every registry call as `curl --cacert "$(CA_CERT)"`. The file is
**gitignored** and copied locally from the git host (qp-ssh and qp-stunnel share
it). It never reaches a target host and is not part of the rpm.

---

## Other config knobs (`qp-stunnel.conf`)

| Directive | Default | Notes |
|---|---|---|
| `accept` | `9443` | operator provisioning pins this to the node's **mesh-interface** address. The default binds all interfaces; the mesh nftables ruleset + the `qp_stunnel_port_t` label gate who can actually reach it. |
| `connect` | `127.0.0.1:8080` | the local plaintext backend. Its port must be labeled `qp_stunnel_backend_port_t` (below). |
| `sslVersion` | `TLSv1.3` | pure PQ; do not lower. |
| `curves` | `MLKEM1024` | ML-KEM-1024 key exchange only. |

> stunnel has **no inline comments** — keep every `;` note on its own line, or the
> rest of the directive line is swallowed into the value.

---

## SELinux at a glance

The custom `qp_stunnel_t` domain is **enforcing** with no capabilities. Two port
types gate its network reach; the rpm `%post` handles the listener, you handle the
backend:

```sh
# listener — done automatically by the rpm %post:
semanage port -a -t qp_stunnel_port_t -p tcp 9443

# backend — you label the one port qp-stunnel may forward to:
sudo semanage port -a -t qp_stunnel_backend_port_t -p tcp <backend-port>
```

`qp_stunnel_t` is allowed to `name_connect` to **only** `qp_stunnel_backend_port_t`
— not a broad "connect anywhere" grant — so an unlabeled backend port is a connect
denial by design. Label exactly the backend you intend.
