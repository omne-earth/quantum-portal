# qp-ssh.spec — RPM that reproduces the install.sh.in pipeline so the install
# story collapses to `dnf install qp-ssh-<ver>.x86_64.rpm`.
#
# The post-quantum OpenSSH suite (OQS-openssh + liboqs + private OpenSSL) is
# prebuilt by `make -f Makefile.publish package` into the .qp tree and staged
# into a payload tarball (Source0) laid out at final paths. This spec untars it
# and wires up the host (host keys, systemd, SELinux, port).
%{!?qp_version: %global qp_version 1.0.0}

# Prebuilt payload shipped verbatim — disable rpm's post-build transforms so the
# binaries + bundled .so land exactly as built.
%global debug_package %{nil}
%global __os_install_post %{nil}

# The bundled openssl/liboqs (.so under /usr/local/qp/lib) are rpath'd and
# satisfied at runtime, but the binaries link them with version symbols the host
# can't provide (e.g. libcrypto.so.3(OPENSSL_3.6.0)). Drop those bundled-lib
# Requires BY NAME so they aren't auto-required from any binary — real system
# deps (libc, libpam, libz) are kept. Don't let the bundled libs pollute Provides.
%global __requires_exclude ^(libcrypto\.so|libssl\.so|liboqs\.so).*$
%global __provides_exclude_from ^/usr/local/qp/lib/.*$

Name:           qp-ssh
Version:        %{qp_version}
Release:        1%{?dist}
Summary:        Post-quantum OpenSSH suite (qp-sshd + qp-ssh)

License:        BSD-2-Clause AND MIT
URL:            https://omne.earth
Source0:        %{name}-payload-%{version}.tar.gz

ExclusiveArch:  x86_64

# pam/zlib: linked by openssh. The bundled openssl/liboqs need no system dep.
Requires:       pam
Requires:       zlib
Requires(pre):  shadow-utils
%{?systemd_requires}

%description
qp-ssh is a post-quantum OpenSSH suite — OQS-OpenSSH + liboqs + a private
OpenSSL — program-prefixed "qp-" and installed under /usr/local/qp.

  * qp-sshd  — PQ SSH daemon on port 1716 (mlkem1024 KEX, ML-DSA-87 +
               Falcon-1024 host/pubkeys), confined by a custom SELinux domain.
  * qp-ssh   — PQ SSH client, pre-configured to reach a qp-sshd with no flags.

After install the host works as both server and client with no further setup
beyond a per-user identity key.

%prep
# Source0 is laid out at final paths; untarred directly in %%install.

%build
# Prebuilt by `make -f Makefile.publish package`.

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
tar -xzf %{SOURCE0} -C %{buildroot}

# =============================================================================
# SCRIPTLETS — reproduce install.sh.in on the target
# =============================================================================

%pre
# OpenSSH privilege-separation user. Stock hosts already have it; create only if
# absent (sysusers.d also declares it for the rpm Provides).
getent group sshd >/dev/null || groupadd -r sshd
getent passwd sshd >/dev/null || \
  useradd -r -g sshd -d /var/empty -s /usr/sbin/nologin -c "Privilege-separated SSH" sshd
exit 0

%post
# privsep chroot jail.
mkdir -p -m 0755 /var/empty

# Host keys (PQ). Fast + offline; generated once, kept across reinstall.
KG=/usr/local/qp/bin/qp-ssh-keygen
[ -f /usr/local/qp/etc/qp-ssh_host_mldsa87_key ] || \
  "$KG" -t ssh-mldsa-87 -f /usr/local/qp/etc/qp-ssh_host_mldsa87_key -N "" >/dev/null 2>&1 || :
[ -f /usr/local/qp/etc/qp-ssh_host_falcon1024_key ] || \
  "$KG" -t ssh-falcon1024 -f /usr/local/qp/etc/qp-ssh_host_falcon1024_key -N "" >/dev/null 2>&1 || :

# SELinux: load the custom qp_sshd_t module, label port 1716, relabel the tree.
if command -v semodule >/dev/null 2>&1 && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
  semodule -i /usr/share/selinux/packages/qp_ssh.pp || :
  if command -v semanage >/dev/null 2>&1; then
    semanage port -a -t qp_ssh_port_t -p tcp 1716 2>/dev/null \
      || semanage port -m -t qp_ssh_port_t -p tcp 1716 2>/dev/null || :
  fi
  restorecon -RF /usr/local/qp 2>/dev/null || :
fi

# install-unit: enable + start (units aren't in a preset, so enable explicitly).
%systemd_post qp-sshd.service
systemctl daemon-reload || :
systemctl enable qp-sshd.service 2>/dev/null || :
if [ $1 -eq 1 ]; then
  systemctl start qp-sshd.service || \
    echo "qp-ssh: qp-sshd did not start cleanly — check 'journalctl -u qp-sshd'."
fi
exit 0

%preun
%systemd_preun qp-sshd.service
exit 0

%postun
%systemd_postun_with_restart qp-sshd.service
# Full removal only ($1 == 0): drop the SELinux module + port label, and the
# runtime-generated host keys (rpm doesn't track them).
if [ $1 -eq 0 ]; then
  if command -v semanage >/dev/null 2>&1; then
    semanage port -d -t qp_ssh_port_t -p tcp 1716 2>/dev/null || :
  fi
  if command -v semodule >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    semodule -r qp_ssh 2>/dev/null || :
  fi
  rm -rf /usr/local/qp /var/empty
fi
exit 0

%files
# Enumerate the suite subtree (no single recursive /usr/local/qp entry) so the
# %config files below aren't listed twice. Binaries + bundled openssl/liboqs +
# libexec helpers + headers + man pages; root-owned, daemon privsep-drops to sshd.
%dir /usr/local/qp
/usr/local/qp/bin
/usr/local/qp/sbin
/usr/local/qp/lib
/usr/local/qp/libexec
/usr/local/qp/include
/usr/local/qp/share
# bundled OpenSSL config dir (openssl.cnf etc.) so the CLI's config-dependent
# commands work (req/ca/x509 -> c_rehash).
/usr/local/qp/ssl

# Config tree. The two opinionated configs are %config(noreplace) so operator
# edits survive upgrades; sshd_config/moduli are the stock build outputs. Host
# keys are %post-generated and deliberately NOT packaged.
%dir /usr/local/qp/etc
%config(noreplace) /usr/local/qp/etc/qp-sshd_config
%config(noreplace) /usr/local/qp/etc/ssh_config
/usr/local/qp/etc/sshd_config
/usr/local/qp/etc/moduli

# systemd unit, sysusers.d, SELinux policy package.
%attr(0644,root,root) /etc/systemd/system/qp-sshd.service
%attr(0644,root,root) /usr/lib/sysusers.d/qp-ssh.conf
%attr(0644,root,root) /usr/share/selinux/packages/qp_ssh.pp

%changelog
* Tue Jun 02 2026 Omne <we@omne.earth> - 1.0.0-1
- Initial RPM packaging of the qp-ssh post-quantum OpenSSH suite.
- Custom qp_sshd_t SELinux domain; first-boot PQ host-key generation.
