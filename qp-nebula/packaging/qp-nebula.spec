# qp-nebula.spec - RPM for the post-quantum overlay-mesh daemon. Like the sibling
# specs it ships a prebuilt payload (Source0) laid out at final paths and untars it,
# then wires the host (user, systemd, SELinux, port). UNLIKE qp-stunnel it has NO
# qp-ssh dependency: nebula is a single pure-Go static binary that links none of the
# bundled OpenSSL/liboqs - so it co-owns only the shared /usr/local/qp dirs it uses
# (rpm permits shared directory ownership) and is installable on its own.
%{!?qp_version: %global qp_version 1.0.0}

# Prebuilt payload shipped verbatim - disable rpm's post-build transforms so the
# static Go binaries land exactly as built.
%global debug_package %{nil}
%global __os_install_post %{nil}

Name:           qp-nebula
Version:        %{qp_version}
Release:        1%{?dist}
Summary:        Post-quantum overlay mesh daemon (ML-KEM-1024 pqIX + ML-DSA-87 CA)

License:        MIT
URL:            https://omne.earth
Source0:        %{name}-payload-%{version}.tar.gz

ExclusiveArch:  x86_64

Requires(pre):  shadow-utils
%{?systemd_requires}

%description
qp-nebula is a post-quantum hardening of the Nebula overlay mesh: the tunnel
handshake is a pure ML-KEM-1024 pqIX-analog and the CA signs with ML-DSA-87. It is a
single static Go binary that creates a tun device, speaks UDP on port 4242, and is
confined by a custom SELinux domain (qp_nebula_t) holding exactly one capability,
CAP_NET_ADMIN. The node cert, key, and CA are provisioned out of band - so the
service ships enabled-not-started and comes up once they exist and the lighthouse is
reachable. `nebula ctl` drives the running daemon over a local unix control socket;
remote control forwards that socket over qp-ssh.

%prep
# Source0 is laid out at final paths; untarred directly in %%install.

%build
# Prebuilt by `make -f Makefile.publish package` (go build + selinux .pp in the toolbox).

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}
tar -xzf %{SOURCE0} -C %{buildroot}

# =============================================================================
# SCRIPTLETS
# =============================================================================

%pre
# Unprivileged service user (sysusers.d also declares it for the rpm Provides).
getent group qp-nebula >/dev/null || groupadd -r qp-nebula
getent passwd qp-nebula >/dev/null || \
  useradd -r -g qp-nebula -d / -s /usr/sbin/nologin -c "qp-nebula PQ overlay mesh" qp-nebula
exit 0

%post
# SELinux: load the qp_nebula_t module, label udp/4242, relabel our files.
if command -v semodule >/dev/null 2>&1 && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
  semodule -i /usr/share/selinux/packages/qp_nebula.pp || :
  if command -v semanage >/dev/null 2>&1; then
    semanage port -a -t qp_nebula_port_t -p udp 4242 2>/dev/null \
      || semanage port -m -t qp_nebula_port_t -p udp 4242 2>/dev/null || :
  fi
  restorecon -RF /usr/local/qp/sbin/qp-nebula /usr/local/qp/bin/qp-nebula-cert \
    /usr/local/qp/etc/nebula 2>/dev/null || :
fi

%systemd_post qp-nebula.service
systemctl daemon-reload || :
systemctl enable qp-nebula.service 2>/dev/null || :
# Deliberately NOT started: qp-nebula needs its CA-signed cert/key provisioned and a
# reachable lighthouse. Provisioning starts it once they exist.
if [ $1 -eq 1 ]; then
  echo "qp-nebula: provision /usr/local/qp/etc/nebula/{ca.crt,host.crt,host.key},"
  echo "           set lighthouse + static_host_map in config.yml, then"
  echo "           'systemctl start qp-nebula'."
fi
exit 0

%preun
%systemd_preun qp-nebula.service
exit 0

%postun
%systemd_postun_with_restart qp-nebula.service
# Full removal only ($1 == 0): drop the SELinux module + port label.
if [ $1 -eq 0 ]; then
  if command -v semanage >/dev/null 2>&1; then
    semanage port -d -t qp_nebula_port_t -p udp 4242 2>/dev/null || :
  fi
  if command -v semodule >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    semodule -r qp_nebula 2>/dev/null || :
  fi
fi
exit 0

%files
# qp-nebula co-owns the shared prefix dirs (rpm allows multiple packages to own a
# directory) so it installs WITH OR WITHOUT qp-ssh/qp-stunnel. It fully owns only its
# own files + the nebula/ config subdir.
%dir /usr/local/qp
%dir /usr/local/qp/sbin
%dir /usr/local/qp/bin
%dir /usr/local/qp/etc
/usr/local/qp/sbin/qp-nebula
/usr/local/qp/sbin/qp-nebula-uninstall
/usr/local/qp/bin/qp-nebula-cert
%dir /usr/local/qp/etc/nebula
# Opinionated config - %config(noreplace) so operator edits survive upgrades. The
# cert/key/ca are provisioned out of band and deliberately NOT packaged.
%config(noreplace) /usr/local/qp/etc/nebula/config.yml
# systemd unit, sysusers.d, SELinux policy package.
%attr(0644,root,root) /etc/systemd/system/qp-nebula.service
%attr(0644,root,root) /usr/lib/sysusers.d/qp-nebula.conf
%attr(0644,root,root) /usr/share/selinux/packages/qp_nebula.pp

%changelog
* Mon Jun 08 2026 Omne <we@omne.earth> - 1.0.0-1
- Initial RPM packaging of qp-nebula, the PQ overlay-mesh daemon.
- pqIX ML-KEM-1024 + ML-DSA-87; custom qp_nebula_t domain (one cap: CAP_NET_ADMIN).
