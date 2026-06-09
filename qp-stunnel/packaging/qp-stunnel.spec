# qp-stunnel.spec — RPM for the post-quantum TLS terminator. Like qp-ssh's spec it
# ships a prebuilt payload (Source0) laid out at final paths and untars it, then
# wires the host (user, systemd, SELinux, port). qp-stunnel is small: a single
# stunnel binary that rpath-links qp-ssh's bundled OpenSSL (the only TLS stack with
# native ML-KEM-1024 / ML-DSA-87) — so it hard-depends on qp-ssh.
%{!?qp_version: %global qp_version 1.0.0}

# Prebuilt payload shipped verbatim — disable rpm's post-build transforms so the
# binary lands exactly as built (rpath to /usr/local/qp/lib intact).
%global debug_package %{nil}
%global __os_install_post %{nil}

# The bundled libssl/libcrypto (under /usr/local/qp/lib, owned by qp-ssh) are
# rpath'd and satisfied at runtime, but carry version symbols the host can't
# provide (e.g. libcrypto.so.3(OPENSSL_3.6.0)). Drop those bundled-lib Requires BY
# NAME so they aren't auto-required from the binary — real system deps (libc,
# libz) are kept; qp-ssh (Requires below) guarantees the bundled .so are present.
%global __requires_exclude ^(libcrypto\.so|libssl\.so).*$

Name:           qp-stunnel
Version:        %{qp_version}
Release:        1%{?dist}
Summary:        Post-quantum TLS terminator (ML-KEM-1024 + ML-DSA-87)

License:        GPL-2.0-or-later
URL:            https://omne.earth
Source0:        %{name}-payload-%{version}.tar.gz

ExclusiveArch:  x86_64

# Hard dependency on qp-ssh: qp-stunnel rpath-links its bundled OpenSSL under
# /usr/local/qp/lib.
Requires:       qp-ssh
Requires(pre):  shadow-utils
%{?systemd_requires}

%description
qp-stunnel is a post-quantum TLS 1.3 terminator for the operator overlay mesh. It
accepts connections on port 9443, completes an ML-KEM-1024 key exchange against an
ML-DSA-87 server certificate, and forwards the decrypted plaintext to a local
backend — giving any plaintext service a pure-PQ edge with no application changes.

It links qp-ssh's bundled OpenSSL (the native ML-KEM / ML-DSA stack), runs as the
unprivileged qp-stunnel user, and is confined by a custom SELinux domain
(qp_stunnel_t) with no capabilities. The cert, key, and (for mutual TLS) client CA
are EJBCA-issued and provisioned out of band — not shipped here — so the service
stays stopped until they exist.

%prep
# Source0 is laid out at final paths; untarred directly in %%install.

%build
# Prebuilt by `make -f Makefile.publish package` (stunnel compiled in the toolbox).

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
tar -xzf %{SOURCE0} -C %{buildroot}

# =============================================================================
# SCRIPTLETS
# =============================================================================

%pre
# Unprivileged service user (sysusers.d also declares it for the rpm Provides).
getent group qp-stunnel >/dev/null || groupadd -r qp-stunnel
getent passwd qp-stunnel >/dev/null || \
  useradd -r -g qp-stunnel -d / -s /usr/sbin/nologin -c "qp-stunnel PQ-TLS terminator" qp-stunnel
exit 0

%post
# SELinux: load the qp_stunnel_t module, label port 9443, relabel our files.
if command -v semodule >/dev/null 2>&1 && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
  semodule -i /usr/share/selinux/packages/qp_stunnel.pp || :
  if command -v semanage >/dev/null 2>&1; then
    semanage port -a -t qp_stunnel_port_t -p tcp 9443 2>/dev/null \
      || semanage port -m -t qp_stunnel_port_t -p tcp 9443 2>/dev/null || :
  fi
  restorecon -F /usr/local/qp/sbin/qp-stunnel /usr/local/qp/etc/qp-stunnel.conf 2>/dev/null || :
fi

%systemd_post qp-stunnel.service
systemctl daemon-reload || :
systemctl enable qp-stunnel.service 2>/dev/null || :
# Deliberately NOT started here: qp-stunnel needs its EJBCA cert/key provisioned
# and the operator mesh + backend up. opoerator provisioning starts it once they exist.
if [ $1 -eq 1 ]; then
  echo "qp-stunnel: provision /usr/local/qp/etc/qp-stunnel.{crt,key}"
  echo "            set accept + backend in qp-stunnel.conf, then 'systemctl start qp-stunnel'."
fi
exit 0

%preun
%systemd_preun qp-stunnel.service
exit 0

%postun
%systemd_postun_with_restart qp-stunnel.service
# Full removal only ($1 == 0): drop the SELinux module + port label.
if [ $1 -eq 0 ]; then
  if command -v semanage >/dev/null 2>&1; then
    semanage port -d -t qp_stunnel_port_t -p tcp 9443 2>/dev/null || :
  fi
  if command -v semodule >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    semodule -r qp_stunnel 2>/dev/null || :
  fi
fi
exit 0

%files
# qp-stunnel's OWN files only — the /usr/local/qp tree + its etc/ dir are owned by
# the qp-ssh rpm (a hard Requires), so they are deliberately not re-listed here.
/usr/local/qp/sbin/qp-stunnel
/usr/local/qp/sbin/qp-stunnel-uninstall
# Opinionated config — %config(noreplace) so operator edits survive upgrades.
%config(noreplace) /usr/local/qp/etc/qp-stunnel.conf
# systemd unit, sysusers.d, SELinux policy package.
%attr(0644,root,root) /etc/systemd/system/qp-stunnel.service
%attr(0644,root,root) /usr/lib/sysusers.d/qp-stunnel.conf
%attr(0644,root,root) /usr/share/selinux/packages/qp_stunnel.pp

%changelog
* Tue Jun 02 2026 Omne <we@omne.earth> - 1.0.0-1
- Initial RPM packaging of qp-stunnel, the PQ-TLS terminator for the operator mesh.
- ML-KEM-1024 + ML-DSA-87 over qp-ssh's bundled OpenSSL; custom qp_stunnel_t domain.
