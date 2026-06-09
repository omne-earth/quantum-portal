#!/usr/bin/env bash
# qp-ssh-uninstall — fully remove the qp-ssh post-quantum SSH stack from this
# host (daemon, binaries, unit, config, host keys, SELinux module + port label).
#
# Installed by the rpm at /usr/local/qp/sbin/qp-ssh-uninstall and reused by
# `make -f Makefile.publish clean`. Idempotent; works whether qp-ssh was
# installed via the rpm or `make bootstrap`/`install.sh`.
#
#   sudo qp-ssh-uninstall
set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo -- "$0" "$@"
fi

echo "[qp-ssh-uninstall] stopping + disabling qp-sshd"
systemctl disable --now qp-sshd.service 2>/dev/null || true
systemctl reset-failed qp-sshd.service 2>/dev/null || true

echo "[qp-ssh-uninstall] removing the rpm (its %postun handles most teardown)"
command -v dnf >/dev/null 2>&1 && dnf remove -y qp-ssh 2>/dev/null || true
# Self-heal a phantom rpmdb entry (aborted erase leaves the db record while the
# files get removed below -> a re-install of the same NEVRA then no-ops).
if command -v rpm >/dev/null 2>&1 && rpm -q qp-ssh >/dev/null 2>&1; then
  echo "[qp-ssh-uninstall] clearing leftover rpmdb entry (rpm -e --noscripts)"
  rpm -e --noscripts --nodeps qp-ssh 2>/dev/null || true
fi

echo "[qp-ssh-uninstall] removing leftover files (e.g. a make bootstrap install)"
rm -f /etc/systemd/system/qp-sshd.service
rm -f /usr/lib/sysusers.d/qp-ssh.conf
rm -f /usr/share/selinux/packages/qp_ssh.pp
rm -rf /usr/local/qp
systemctl daemon-reload 2>/dev/null || true

echo "[qp-ssh-uninstall] dropping SELinux module + port label"
if command -v semodule >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
  semodule -r qp_ssh 2>/dev/null || true
fi
command -v semanage >/dev/null 2>&1 && semanage port -d -t qp_ssh_port_t -p tcp 1716 2>/dev/null || true

# Deliberately leave the shared 'sshd' privsep user and /var/empty — both are
# used by the system's own openssh-server.
echo "[qp-ssh-uninstall] done."
