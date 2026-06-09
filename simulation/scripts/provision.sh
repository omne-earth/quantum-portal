#!/usr/bin/env bash
# CoW-clone the base image into the inventory's node VMs and start them on the
# isolated mgmt + underlay networks. Each clone is a real machine - one qp-nebula
# node. Idempotent. Run after 'make base'.
set -euo pipefail
LOG_TAG=provision
. "$(dirname "$0")/common.sh"

INV="${1:?usage: provision.sh <inventory.env>}"
. "$INV"   # defines NODES=(name:role ...)
[ -f "$QPN_BASE" ] || die "base image missing ($QPN_BASE) - run 'make -C simulation base'"
mkdir -p "$QPN_BUILD"
TMPL="$SIM/domains/node.xml.template"

for entry in "${NODES[@]}"; do
  n="${entry%%:*}"; d="$(dom "$n")"; disk="$QPN_IMG_DIR/$n${QPN_SUFFIX:-}.qcow2"
  unet="${NET[$n]:-$NET_UNDERLAY}"   # per-node underlay net (relay-nat puts nodes on per-node NAT nets)
  $VIRSH destroy  "$d" 2>/dev/null || true
  $VIRSH undefine "$d" --nvram 2>/dev/null || true
  rm -f "$disk"
  qemu-img create -q -f qcow2 -F qcow2 -b "$QPN_BASE" "$disk"
  sed -e "s|{{NODE}}|$d|g" -e "s|{{DISK}}|$disk|g" -e "s|{{ULAYNET}}|$unet|g" "$TMPL" > "$QPN_BUILD/$n${QPN_SUFFIX:-}.xml"
  $VIRSH define "$QPN_BUILD/$n${QPN_SUFFIX:-}.xml" >/dev/null
  $VIRSH start  "$d" >/dev/null
  log "$d started"
done
log "${#NODES[@]} node VM(s) up"
