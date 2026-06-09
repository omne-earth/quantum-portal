#!/usr/bin/env bash
# qp-stunnel-uninstall — fully remove the qp-stunnel PQ-TLS terminator from this
# host (daemon, binary, unit, config, SELinux module + port label).
#
# Installed by the rpm at /usr/local/qp/sbin/qp-stunnel-uninstall and reused by
# `make -f Makefile.publish clean`. Idempotent. Deliberately scoped to qp-stunnel's
# OWN files — it never touches the shared /usr/local/qp tree or the bundled OpenSSL,
# both owned by the qp-ssh rpm this binary depends on.
#
#   sudo qp-stunnel-uninstall
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

echo "[qp-stunnel-uninstall] stopping + disabling qp-stunnel"
systemctl disable --now qp-stunnel.service 2>/dev/null || true
systemctl reset-failed qp-stunnel.service 2>/dev/null || true

echo "[qp-stunnel-uninstall] removing the rpm (its %postun handles most teardown)"
command -v dnf >/dev/null 2>&1 && dnf remove -y qp-stunnel 2>/dev/null || true
# Self-heal a phantom rpmdb entry (aborted erase leaves the db record while the
# files get removed below -> a re-install of the same NEVRA then no-ops).
if command -v rpm >/dev/null 2>&1 && rpm -q qp-stunnel >/dev/null 2>&1; then
  echo "[qp-stunnel-uninstall] clearing leftover rpmdb entry (rpm -e --noscripts)"
  rpm -e --noscripts --nodeps qp-stunnel 2>/dev/null || true
fi

echo "[qp-stunnel-uninstall] removing leftover files (e.g. a make-staged install)"
rm -f /etc/systemd/system/qp-stunnel.service
rm -f /usr/lib/sysusers.d/qp-stunnel.conf
rm -f /usr/share/selinux/packages/qp_stunnel.pp
# qp-stunnel's OWN files under the shared prefix — NOT the prefix itself.
rm -f /usr/local/qp/sbin/qp-stunnel /usr/local/qp/sbin/qp-stunnel-uninstall
rm -f /usr/local/qp/etc/qp-stunnel.conf
systemctl daemon-reload 2>/dev/null || true

echo "[qp-stunnel-uninstall] dropping SELinux module + port label"
if command -v semodule >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  semodule -r qp_stunnel 2>/dev/null || true
fi
command -v semanage >/dev/null 2>&1 && semanage port -d -t qp_stunnel_port_t -p tcp 9443 2>/dev/null || true

# Deliberately left in place: the qp-stunnel service user (conventional for system
# users) and the provisioned cert/key (qp-stunnel.crt/.key — operator-managed).
echo "[qp-stunnel-uninstall] done."
