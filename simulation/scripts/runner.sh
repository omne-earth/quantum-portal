#!/usr/bin/env bash
# Boot ONE throwaway VM, install the given rpm(s), and run an arbitrary check script inside
# it (real systemd + SELinux-enforcing) - the deployment tier the rootless toolbox can't
# host. Generic: the caller supplies the rpms, the check script, and its env. Reuses the
# SAME base image, mgmt net, provision key, provision.sh, and common.sh helpers as the
# qp-nebula sim (one node = one VM).
#   runner.sh <inventory.env>
# Env (from the caller):
#   RUNNER_RPMS="rpm..."     host rpm path(s), installed in one dnf transaction (order/deps)
#   RUNNER_CHECK="check.sh"  host path to the script run in-VM as root
#   RUNNER_ENV="VAR=val ..." optional env prefixed to the in-VM check invocation
#   RUNNER_ASSETS="dir"      optional dir pushed alongside; exposed to the check as $QP_ASSETS
set -euo pipefail
LOG_TAG=runner
. "$(dirname "$0")/common.sh"

INV="${1:?usage: runner.sh <inventory.env>}"
: "${RUNNER_RPMS:?set RUNNER_RPMS=<rpm...>}"
: "${RUNNER_CHECK:?set RUNNER_CHECK=<check.sh>}"
. "$INV"                                  # NODES=( "name:role" )
[ -f "$QPN_BASE" ] || die "base image missing ($QPN_BASE) - run 'make -C simulation base'"
for r in $RUNNER_RPMS; do [ -f "$r" ] || die "rpm not found: $r"; done
[ -f "$RUNNER_CHECK" ] || die "check script not found: $RUNNER_CHECK"

destroy_nodes; trap on_exit EXIT          # clean slate; teardown on success, keep on failure
"$SIM/scripts/provision.sh" "$INV"

n="${NODES[0]%%:*}"; d="$(dom "$n")"
log "waiting for $d (ssh)"
addr="$(wait_ssh "$d")" || die "$d never came up on mgmt"
log "$d up @ $addr"

# Push + install the rpm(s) in ONE dnf transaction (resolves inter-rpm order + deps). The
# rpms are GPG-signed and that chain is verified by the host `install` target; the isolated
# lab VM has no registry/key plumbing, so it installs with --nogpgcheck.
rpaths=""
for r in $RUNNER_RPMS; do b="$(basename "$r")"; npush "$addr" "$r" "/tmp/$b"; rpaths+=" /tmp/$b"; done
log "installing:$rpaths"
# --disablerepo='*': the mgmt net is isolated (no internet), so resolve deps ONLY from
# the local rpm(s) + what the base image already ships (pam/zlib/systemd are in it).
nssh "$addr" "dnf install -y --disablerepo='*' --nogpgcheck$rpaths" || die "rpm install failed in $d"

# Push the check's whole directory (its sibling helpers come along) + an optional asset
# dir (e.g. the component's test-*.sh), then run the check as root in the VM.
cdir="$(cd "$(dirname "$RUNNER_CHECK")" && pwd)"; cb="$(basename "$RUNNER_CHECK")"
nssh "$addr" 'rm -rf /tmp/qpcheck /tmp/qpassets'
npush "$addr" "$cdir" "/tmp/qpcheck"      # -> /tmp/qpcheck/<check + siblings>
aenv=""
if [ -n "${RUNNER_ASSETS:-}" ]; then
  npush "$addr" "$RUNNER_ASSETS" "/tmp/qpassets"
  aenv="QP_ASSETS=/tmp/qpassets"
fi
log "running $cb in $d"
nssh "$addr" "${RUNNER_ENV:-} $aenv bash /tmp/qpcheck/$cb" || die "$cb FAILED in $d"

echo "qp sim runner: PASS ($d, $cb)"
