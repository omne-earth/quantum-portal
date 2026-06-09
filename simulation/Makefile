# simulation/Makefile - the libvirt golden-base + network lifecycle for the qp-* sims.
#
# First-class IAC module: owns the shared Fedora base qcow2 (node VMs clone it
# copy-on-write) and the isolated networks. The per-topology runs (tunnel, mesh,
# stress-*) live in the consuming component's Makefile (e.g. qp-nebula), which drives
# this module's scripts/ + inventory/ + net/ directly. This Makefile only BUILDS and
# PURGES that shared infrastructure.
#
#   make -C simulation provision-key  # generate the gitignored lab SSH key (once)
#   make -C simulation base           # build the Fedora base qcow2 (once; ~15 min)
#                                      #   needs QPN_FEDORA_ISO=/path/to/Fedora-Server-dvd-*.iso
#   make -C simulation nets           # define + start the networks (idempotent)
#   make -C simulation clean-prefix DOM_PREFIX=qpssh  # purge ONE project's VM domains
#   make -C simulation clean          # purge every project's domains + the nets + base image
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
HERE := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
VIRSH := virsh -q -c qemu:///system
KEY := $(HERE)/.ssh/provision_key

# Shared repo config. QPN_FEDORA_ISO (the golden-image source ISO) lives here, alongside the
# other vendor/site values; optional so the sim's net/clean targets work without it (only the
# `base` build needs it). Exported so the base recipe's build-base.sh reads it from the env.
-include $(HERE)/../.env
export QPN_FEDORA_ISO

# Every net/<name>.xml is one entry: mgmt + node (shared, in net/) + pub + per-node NAT
# nets (the real symmetric-NAT relay topology).
NETS := mgmt node pub nat1 nat2 \
        tA tB tAA tAB tBA tBB

# Golden base image - mirrors scripts/common.sh's QPN_IMG_DIR default. The image file IS the
# sentinel: every VM run depends on `base`, which builds it only when the qcow2 is absent
# and is a no-op once it exists. `make -C simulation purge` removes it to force a rebuild.
IMG_DIR := /var/lib/libvirt/images/qp-nebula
BASE    := $(IMG_DIR)/base.qcow2

# Domain (VM) name prefix - the create-side default (common.sh) is qp; each project's clean
# target overrides it to match the prefix that project creates its VMs under.
DOM_PREFIX ?= qp

# Every project's VM-domain prefix - purge iterates clean-prefix over these.
DOM_PREFIXES := qpssh qpstunnel qpnebula

.PHONY: provision-key nets base clean-prefix clean purge

# Generate the sim's provision key ONCE. Sentinel = the key file itself ($(KEY)), so
# re-running is a no-op; every VM run depends on it. Self-generated, passphrase-less,
# isolated-lab key - gitignored, NEVER checked in. Remove $(KEY)* to regenerate.
# This phony target also RE-ASSERTS 0600 on every run: ssh refuses a world-readable private
# key (falling back to a password prompt), and a stray checkout/copy can loosen the bit.
provision-key: $(KEY)
	@chmod 600 $(KEY)
$(KEY):
	@command -v ssh-keygen >/dev/null || { echo "[provision-key] ssh-keygen not found"; exit 1; }
	@mkdir -p $(HERE)/.ssh && chmod 700 $(HERE)/.ssh
	ssh-keygen -t ed25519 -N "" -C qp-sim-provision -f $(KEY)
	@chmod 600 $(KEY)
	@echo "[provision-key] generated $(KEY) (gitignored; isolated lab key)"

# Define + start the networks in $(NETS) (idempotent). Each calling target passes the
# SUBSET it actually uses, e.g. `nets NETS="mgmt node"`; with no override it brings up all
# of them. The shared nets live in net/; project-specific ones in net/<project>/ (e.g.
# net/qp-nebula/), so the define looks in both. purge tears them back down.
nets:
	for n in $(NETS); do \
	  xml=$(HERE)/net/$$n.xml; [ -f "$$xml" ] || xml=$(HERE)/net/qp-nebula/$$n.xml; \
	  $(VIRSH) net-info $$n >/dev/null 2>&1 || $(VIRSH) net-define "$$xml"; \
	  $(VIRSH) net-start $$n 2>/dev/null || true; \
	  $(VIRSH) net-autostart $$n 2>/dev/null || true; \
	done

# Build the golden base image (unattended Fedora Server install via kickstart). Sentinel'd
# on the image file: skipped when $(BASE) already exists, built (slow; needs QPN_FEDORA_ISO)
# when it's missing. Every VM run depends on `base`, so the image is created once on first
# use and reused thereafter.
base: $(BASE)
$(BASE): $(KEY)
	$(HERE)/scripts/build-base.sh

# Tear down the VM domains for ONE project, keyed by DOM_PREFIX — the same prefix that
# project's smoke/stress targets create their VMs under (qpssh, qpstunnel, or the default
# qp for qp-nebula). Parameterized like the create-side: `make -C simulation clean
# DOM_PREFIX=qpssh`. The per-project targets below preset it.
clean-prefix:
	@echo "[clean] purging $(DOM_PREFIX)-* domains"
	for d in $$($(VIRSH) list --all --name | grep -E '^$(DOM_PREFIX)-' || true); do \
	  $(VIRSH) destroy  $$d 2>/dev/null || true; \
	  $(VIRSH) undefine $$d --nvram 2>/dev/null || true; \
	done

# clean: tear down the SHARED infra - the networks + the golden base image + build
# tree. The expensive golden image is rebuilt by `make -C simulation base`. Per-project
# VM domains are torn down by the harness (destroy_nodes) or by purge.
clean:
	@echo "[clean] purging networks + the golden base image"
	for n in $(NETS); do \
	  $(VIRSH) net-destroy  $$n 2>/dev/null || true; \
	  $(VIRSH) net-undefine $$n 2>/dev/null || true; \
	done
	rm -f $(IMG_DIR)/*.qcow2
	rm -rf $(HERE)/.build
	@echo "[clean] done (rebuild the base with 'make -C simulation base')"

# purge: the full teardown - every project's leftover VM domains (clean-prefix per
# DOM_PREFIX across $(DOM_PREFIXES)), then the shared infra (clean).
purge:
	for p in $(DOM_PREFIXES); do \
	  $(MAKE) -C $(HERE) --no-print-directory clean-prefix DOM_PREFIX=$$p; \
	done
	$(MAKE) -C $(HERE) --no-print-directory clean
