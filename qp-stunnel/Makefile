# qp-stunnel/Makefile — the qp-stunnel component
#
#   make -f qp-stunnel/Makefile build     # compile in the toolbox
#   make -f qp-stunnel/Makefile smoke     # validate the release with tests, runs in a container
#   make -f qp-stunnel/Makefile stress    # extended tests inside a simulated environment
#   make -f qp-stunnel/Makefile package   # GATE: clean -> build -> rpmbuild -> sign
#   make -f qp-stunnel/Makefile install   # deploy the built rpm + smoke (re-runnable)
#   make -f qp-stunnel/Makefile publish   # SHIP: delete-existing + upload the rpm
#   make -f qp-stunnel/Makefile link      # publish, then link to repository
#   make -f qp-stunnel/Makefile clean     # full teardown (rpm + system), keep the toolbox
#
.ONESHELL:
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := link

# Run from the repo ROOT (orchestrator: `-f qp-stunnel/Makefile`); .env anchors
# the cert/artifact paths on $(CURDIR). Fail clearly if run from qp-stunnel/.
ifeq ($(wildcard .env),)
$(error run qp-stunnel from the repo root — `make -f qp-stunnel/Makefile <target>` or via Makefile.publish; .env not found in $(CURDIR))
endif

include .env
BUILD_DIR := $(CURDIR)/.build
include Makefile.commons        # shared fedora toolbox

VERSION := $(QP_VERSION)

# Per-run logs: ONE timestamped file per kind under .logs/ (gitignored), fixed at parse
# time so every target in a single `make` invocation shares it. Smoke recipes start with
# `@$(LOG)` (-> smoke-*.log), stress recipes with `@$(SLOG)` (-> stress-*.log); each tees
# its stdout+stderr to its log (and to the console).
TS         := $(shell date -u +%Y%m%dT%H%M%SZ)
LOG_FILE   := .logs/smoke-qpstunnel-$(TS).log
STRESS_LOG := .logs/stress-qpstunnel-$(TS).log
LOG  = mkdir -p $(dir $(LOG_FILE))   ; exec > >(tee -a "$(LOG_FILE)") 2>&1   ; printf '\n=== %s @ %s ===\n' "$@" "$$(date -u +%FT%TZ)"
SLOG = mkdir -p $(dir $(STRESS_LOG)) ; exec > >(tee -a "$(STRESS_LOG)") 2>&1 ; printf '\n=== %s @ %s ===\n' "$@" "$$(date -u +%FT%TZ)"

# -----------------------------------------------------------------------------
# Build / packaging artifacts. Component-suffixed (payload-stunnel, etc.) so they
# never clobber qp-ssh's when both run under the shared $(BUILD_DIR).
# -----------------------------------------------------------------------------
STUNNEL_BIN := $(CURDIR)/qp-stunnel/.stage/qp-stunnel
PAYLOAD     := $(BUILD_DIR)/payload-stunnel
RPMBUILD    := $(BUILD_DIR)/rpmbuild-stunnel
RPM         := $(CURDIR)/dist/qp-stunnel-$(VERSION)-1.x86_64.rpm

# qp-ssh's bundled, PQ-capable OpenSSL in the BUILD tree (qp-stunnel compiles + smokes
# against it pre-install). The build-tree binaries are RPATH'd to the INSTALL prefix
# ($(QP_PREFIX)/lib), and OpenSSL's compiled-in OPENSSLDIR is $(QP_PREFIX)/ssl - neither
# exists in the toolbox, so the in-toolbox smoke puts the bundled libdir on the loader
# path and points OPENSSL_CONF at the build-tree config. (install/ smoke uses $(QP_PREFIX).)
QP_BUILD_OPENSSL  := $(CURDIR)/.qp/bin/openssl
QP_BUILD_LIBDIR   := $(CURDIR)/.qp/lib
QP_BUILD_OPENSSL_CONF := $(CURDIR)/.qp/ssl/openssl.cnf

# -----------------------------------------------------------------------------
# RPM endpoints — derived from the shared registry base in .env exactly as
# qp-ssh does, just with this component's package name (full parity).
# -----------------------------------------------------------------------------
RPM_PKG                := qp-stunnel
RPM_PACKAGE_URL        := $(RPM_REGISTRY_URL)/$(RPM_PKG)
PACKAGE_LINK_URL_RPM   := $(RPM_PACKAGE_URL)/-/link/$(PACKAGE_LINK_REPO)
PACKAGE_UNLINK_URL_RPM := $(RPM_PACKAGE_URL)/-/unlink
CURL                   := curl -fsS --cacert "$(CA_CERT)"
RPM_DELETE_URL         := $(RPM_PACKAGE_URL)/$(VERSION)-1

export CA_CERT

.PHONY: build smoke smoke-tls smoke-mtls stress stress-tls stress-mtls payload package package-clean uninstall install publish link clean

# The shared libvirt sim (golden base + * nets + provisioning scripts) is the
# first-class simulation/ module; the VM tier of `smoke` drives it. The VM install needs
# qp-ssh's rpm too (it owns the bundled OpenSSL qp-stunnel links). Run from the repo root.
SIM       := $(CURDIR)/simulation
QPSSH_RPM := $(CURDIR)/dist/qp-ssh-$(VERSION)-1.x86_64.rpm

SMOKE_ENV := STUNNEL=$(STUNNEL_BIN) OPENSSL=$(QP_BUILD_OPENSSL) LD_LIBRARY_PATH=$(QP_BUILD_LIBDIR) OPENSSL_CONF=$(QP_BUILD_OPENSSL_CONF)
STRESS_ENV := STUNNEL=$(QP_PREFIX)/sbin/qp-stunnel OPENSSL=$(QP_PREFIX)/bin/openssl

# =============================================================================
# BUILD — compile stunnel in the toolbox against qp-ssh's bundled OpenSSL.
# =============================================================================
build: $(STUNNEL_BIN)
$(STUNNEL_BIN): | $(TOOLBOX_OK)
	@echo "[qp-stunnel] building stunnel against the bundled OpenSSL (toolbox)"
	$(T) make -C qp-stunnel -f Makefile.build build

# =============================================================================
# SMOKE (toolbox) — loopback PQ-TLS termination (the component AC): a real MLKEM1024 +
# ML-DSA-87 handshake is terminated by qp-stunnel and the plaintext forwarded. Two leaf
# targets — smoke-tls (server-auth) + smoke-mtls (mutual TLS) — gathered by the `smoke`
# catch-all. Each runs in the toolbox via $(T) against the BUILD tree, so it needs nothing
# installed on the host (python3 backend + ss are in the toolbox). The build-tree binaries
# are RPATH'd to $(QP_PREFIX)/lib (absent here), so LD_LIBRARY_PATH points the loader at the
# bundled libdir. The INSTALLED-binary equivalents run in a VM under stress-tls/stress-mtls.
# =============================================================================
smoke: smoke-tls smoke-mtls
	@$(LOG)
	@echo "[smoke] PASS"

smoke-tls: $(STUNNEL_BIN) | $(TOOLBOX_OK)
	@$(LOG)
	@echo "[smoke] qp-stunnel loopback PQ-TLS termination, toolbox (server-auth)"
	$(T) bash -c 'cd $(CURDIR) && $(SMOKE_ENV) bash qp-stunnel/scripts/test-pqtls.sh'

smoke-mtls: $(STUNNEL_BIN) | $(TOOLBOX_OK)
	@$(LOG)
	@echo "[smoke] qp-stunnel loopback PQ-TLS termination, toolbox (mutual TLS)"
	$(T) bash -c 'cd $(CURDIR) && $(SMOKE_ENV) MTLS=1 bash qp-stunnel/scripts/test-pqtls.sh'

# =============================================================================
# STRESS (deployment tier, libvirt sim) — the same loopback PQ-TLS tests against the
# INSTALLED qp-stunnel in a clean-room VM (real systemd + SELinux), not the build tree.
# Two leaf targets — stress-tls (server-auth) + stress-mtls (mutual TLS) — gathered by the
# `stress` catch-all. Each boots one confine VM via the shared simulation/ harness,
# dnf-installs the qp-ssh rpm (owns the bundled OpenSSL qp-stunnel links) + the qp-stunnel
# rpm, and runs test-pqtls.sh against the installed $(QP_PREFIX)/sbin/qp-stunnel.
# =============================================================================
stress: stress-tls stress-mtls
	@$(SLOG)
	@echo "[stress] PASS"

stress-tls: $(RPM)
	@$(SLOG)
	@test -f $(QPSSH_RPM) || { echo "[stress] qp-ssh rpm missing ($(QPSSH_RPM)) — build it: make -f qp-ssh/Makefile package"; exit 1; }
	@echo "[stress] qp-stunnel installed-binary PQ-TLS, server-auth (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="mgmt node" provision-key base
	RUNNER_RPMS='$(QPSSH_RPM) $(RPM)' \
	RUNNER_CHECK='$(CURDIR)/qp-stunnel/scripts/test-pqtls.sh' \
	RUNNER_ENV='$(STRESS_ENV)' \
	DOM_PREFIX=qpstunnel QPN_SUFFIX=-tls $(SIM)/scripts/runner.sh $(SIM)/inventory/runner.env

stress-mtls: $(RPM)
	@$(SLOG)
	@test -f $(QPSSH_RPM) || { echo "[stress] qp-ssh rpm missing ($(QPSSH_RPM)) — build it: make -f qp-ssh/Makefile package"; exit 1; }
	@echo "[stress] qp-stunnel installed-binary PQ-TLS, mutual TLS (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="mgmt node" provision-key base
	RUNNER_RPMS='$(QPSSH_RPM) $(RPM)' \
	RUNNER_CHECK='$(CURDIR)/qp-stunnel/scripts/test-pqtls.sh' \
	RUNNER_ENV='$(STRESS_ENV) MTLS=1' \
	DOM_PREFIX=qpstunnel QPN_SUFFIX=-mtls $(SIM)/scripts/runner.sh $(SIM)/inventory/runner.env

# =============================================================================
# PAYLOAD — stage qp-stunnel's OWN files at final filesystem paths. It adds only
# its binary/config/unit/policy under the shared /usr/local/qp prefix (the tree +
# the bundled OpenSSL this binary rpath-links are owned by the qp-ssh rpm).
# =============================================================================
payload: $(STUNNEL_BIN) qp-stunnel/packaging/qp-stunnel.conf qp-stunnel/packaging/qp-stunnel.service \
         qp-stunnel/packaging/qp-stunnel.sysusers qp-stunnel/packaging/qp-stunnel-uninstall.sh \
         qp-stunnel/selinux/qp_stunnel.pp
	rm -rf $(PAYLOAD)
	install -D -m0755 $(STUNNEL_BIN)                                $(PAYLOAD)/usr/local/qp/sbin/qp-stunnel
	install -D -m0755 qp-stunnel/packaging/qp-stunnel-uninstall.sh  $(PAYLOAD)/usr/local/qp/sbin/qp-stunnel-uninstall
	install -D -m0644 qp-stunnel/packaging/qp-stunnel.conf          $(PAYLOAD)/usr/local/qp/etc/qp-stunnel.conf
	install -D -m0644 qp-stunnel/packaging/qp-stunnel.service       $(PAYLOAD)/etc/systemd/system/qp-stunnel.service
	install -D -m0644 qp-stunnel/packaging/qp-stunnel.sysusers      $(PAYLOAD)/usr/lib/sysusers.d/qp-stunnel.conf
	install -D -m0644 qp-stunnel/selinux/qp_stunnel.pp              $(PAYLOAD)/usr/share/selinux/packages/qp_stunnel.pp

# Compile the SELinux module (.te + .fc -> .pp) in the toolbox if stale.
qp-stunnel/selinux/qp_stunnel.pp: qp-stunnel/selinux/qp_stunnel.te qp-stunnel/selinux/qp_stunnel.fc qp-stunnel/selinux/Makefile | $(TOOLBOX_OK)
	$(T) make -C qp-stunnel/selinux

# =============================================================================
# RPM — rpmbuild inside the toolbox, written straight to dist/, then GPG-signed
# with the packaging key (identical pipeline to qp-ssh).
# =============================================================================
$(RPM): payload qp-stunnel/packaging/qp-stunnel.spec | $(TOOLBOX_OK)
	rm -rf $(RPMBUILD)
	mkdir -p $(RPMBUILD)/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS} $(CURDIR)/dist
	tar -C $(PAYLOAD) -czf $(RPMBUILD)/SOURCES/qp-stunnel-payload-$(VERSION).tar.gz .
	cp qp-stunnel/packaging/qp-stunnel.spec $(RPMBUILD)/SPECS/
	$(T) rpmbuild -bb \
	  --define "_topdir $(RPMBUILD)" \
	  --define "qp_version $(VERSION)" \
	  --define "dist %{nil}" \
	  --define "_rpmdir $(CURDIR)/dist" \
	  --define "_rpmfilename $(notdir $(RPM))" \
	  $(RPMBUILD)/SPECS/qp-stunnel.spec
	@test -f $(RPM) || { echo "[package] rpm not written to $(RPM)"; exit 1; }
	# GPG-sign in a throwaway GNUPGHOME (rpm-sign + gnupg2 in the toolbox) so the
	# operator's ~/.gnupg stays untouched; the key carries no passphrase.
	$(T) bash -c 'set -e; export GNUPGHOME="$$(mktemp -d)"; trap "rm -rf $$GNUPGHOME" EXIT; gpg --batch --quiet --import "$(GPG_SIGN_KEY)"; rpmsign --addsign --define "_gpg_name $(GPG_SIGN_NAME)" "$(RPM)"'
	@sig="$$(rpm -Kv $(RPM) 2>&1 || true)"; echo "$$sig" | grep -qiE 'signature, key (id|fingerprint)' || { echo "[package] signing FAILED — $(RPM) is unsigned:"; echo "$$sig"; exit 1; }
	@echo "[package] built + signed $(RPM)"

# =============================================================================
# PACKAGE — rpm build (no install).
# =============================================================================
package:
	@echo "[package] clean build of $(notdir $(RPM))"
	$(MAKE) -f qp-stunnel/Makefile $(RPM)

package-clean: clean package

# =============================================================================
# UNINSTALL — full system teardown via the shipped uninstall script. Idempotent: a
# no-op when nothing is installed (the script self-elevates + tolerates absent state).
# Chained into install so every install starts from a clean slate.
# =============================================================================
uninstall:
	@echo "[uninstall] qp-stunnel system teardown (idempotent)"
	sudo bash qp-stunnel/packaging/qp-stunnel-uninstall.sh || true

# =============================================================================
# INSTALL — deploy the built rpm + smoke (re-runnable). qp-ssh (a hard Requires,
# the bundled OpenSSL) must already be installed. The unit ships enabled-not-
# started (it needs the provisioned cert + mesh + backend), so the smoke validates
# the INSTALLED binary via the same self-contained loopback handshake.
# =============================================================================
install:
	@test -f $(RPM) || { echo "[install] no rpm at $(RPM) — run 'make -f qp-stunnel/Makefile package' first"; exit 1; }
	@rpm -q qp-ssh >/dev/null 2>&1 || { echo "[install] qp-ssh not installed — it owns the bundled OpenSSL qp-stunnel links; install qp-ssh first"; exit 1; }
	# Verify the rpm + signature BEFORE tearing down any existing install.
	sudo rpm --import $(GPG_SIGN_CERT)
	rpm -K $(RPM) | grep -qi 'signatures OK' || { echo "[install] signature verify FAILED:"; rpm -K $(RPM); exit 1; }
	@echo "[install] uninstall -> dnf install -> smoke"
	$(MAKE) -f qp-stunnel/Makefile uninstall
	sudo dnf install -y --setopt=localpkg_gpgcheck=1 $(RPM)
	@echo "[install] loopback PQ smoke against the INSTALLED binary"
	STUNNEL='$(QP_PREFIX)/sbin/qp-stunnel' OPENSSL='$(QP_PREFIX)/bin/openssl' \
	  bash qp-stunnel/scripts/test-pqtls.sh
	@echo "[install] PASS"

# =============================================================================
# PUBLISH — ship the ALREADY-BUILT rpm. No build prereqs. Delete the existing
# upstream version (no-op if absent), then upload. Identical flow to qp-ssh.
# =============================================================================
publish:
	@test -f "$(RPM)" || { echo "[publish] missing $(RPM) — run 'make -f qp-stunnel/Makefile package' first"; exit 1; }
	@sig="$$(rpm -Kv "$(RPM)" 2>&1 || true)"; echo "$$sig" | grep -qiE 'signature, key (id|fingerprint)' || { echo "[publish] $(RPM) is unsigned — run 'make -f qp-stunnel/Makefile package' (it signs)"; exit 1; }
	@echo "[publish] credentials for the RPM registry (write-capable account)"
	read -rp "  username: " u
	read -rsp "  access token: " t; echo
	echo "[publish] qp-stunnel $(VERSION) -> RPM registry"
	$(CURL) -H "Authorization: token $$t" -X DELETE "$(RPM_DELETE_URL)" >/dev/null 2>&1 || true
	$(CURL) -H "Authorization: token $$t" -X PUT --upload-file "$(RPM)" "$(RPM_UPLOAD_URL)"
	echo "[publish] uploaded qp-stunnel $(VERSION)"

# =============================================================================
# LINK (DEFAULT) — publish, then link the rpm package to repository.
# =============================================================================
link: publish
	@echo "[link] credentials for linking (write-capable account)"
	read -rp "  username: " u
	read -rsp "  access token: " t; echo
	echo "[link] rpm: qp-stunnel -> $(PACKAGE_LINK_REPO)"
	$(CURL) -H "Authorization: token $$t" -X POST "$(PACKAGE_UNLINK_URL_RPM)" >/dev/null 2>&1 || true
	$(CURL) -H "Authorization: token $$t" -X POST "$(PACKAGE_LINK_URL_RPM)"   && echo "  linked"

# =============================================================================
# CLEAN — full system teardown via the shipped uninstall script + drop the rpm
# build intermediates and the stunnel build. Keeps the toolbox.
# =============================================================================
clean:
	@echo "[clean] system teardown via the shipped uninstall script"
	sudo bash qp-stunnel/packaging/qp-stunnel-uninstall.sh || true
	@echo "[clean] wiping the stunnel build + rpm intermediates"
	$(MAKE) -C qp-stunnel -f Makefile.build clean
	rm -rf $(PAYLOAD) $(RPMBUILD) $(RPM)
	@echo "[clean] done (toolbox kept)"
