#!/usr/bin/env bash
# qp-nebula-uninstall - fully remove the qp-nebula PQ overlay-mesh daemon from this
# host (daemon, binary, cert tool, unit, config, SELinux module + port label).
#
# Installed by the rpm at /usr/local/qp/sbin/qp-nebula-uninstall and reused by
# `make -f Makefile.publish clean`. Idempotent. Scoped to qp-nebula's OWN files; it
# never removes the shared /usr/local/qp prefix (co-owned with qp-ssh/qp-stunnel when
# present) and never deletes the provisioned cert/key/ca (operator-managed).
#
#   sudo qp-nebula-uninstall
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

echo "[qp-nebula-uninstall] stopping + disabling qp-nebula"
systemctl disable --now qp-nebula.service 2>/dev/null || true
systemctl reset-failed qp-nebula.service 2>/dev/null || true

echo "[qp-nebula-uninstall] removing the rpm (its %postun handles most teardown)"
command -v dnf >/dev/null 2>&1 && dnf remove -y qp-nebula 2>/dev/null || true
# Self-heal a phantom rpmdb entry (aborted erase leaves the db record while the files
# get removed below -> a re-install of the same NEVRA then no-ops).
if command -v rpm >/dev/null 2>&1 && rpm -q qp-nebula >/dev/null 2>&1; then
  echo "[qp-nebula-uninstall] clearing leftover rpmdb entry (rpm -e --noscripts)"
  rpm -e --noscripts --nodeps qp-nebula 2>/dev/null || true
fi

echo "[qp-nebula-uninstall] removing leftover files (e.g. a make-staged install)"
rm -f /etc/systemd/system/qp-nebula.service
rm -f /usr/lib/sysusers.d/qp-nebula.conf
rm -f /usr/share/selinux/packages/qp_nebula.pp
# qp-nebula's OWN files under the shared prefix - NOT the prefix itself.
rm -f /usr/local/qp/sbin/qp-nebula /usr/local/qp/sbin/qp-nebula-uninstall
rm -f /usr/local/qp/bin/qp-nebula-cert
rm -f /usr/local/qp/etc/nebula/config.yml
systemctl daemon-reload 2>/dev/null || true

echo "[qp-nebula-uninstall] dropping SELinux module + port label"
if command -v semodule >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  semodule -r qp_nebula 2>/dev/null || true
fi
command -v semanage >/dev/null 2>&1 && semanage port -d -t qp_nebula_port_t -p udp 4242 2>/dev/null || true

# Deliberately left in place: the qp-nebula service user (conventional for system
# users) and the provisioned ca.crt/host.crt/host.key (operator-managed).
echo "[qp-nebula-uninstall] done."
