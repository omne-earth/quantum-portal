# qp-ssh/Makefile — the qp-ssh component
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
SHELL          := /bin/bash
.SHELLFLAGS    := -euo pipefail -c
.DEFAULT_GOAL  := link

# Invoked from the repo ROOT (the orchestrator uses `-f qp-ssh/Makefile`) because
# .env anchors the cert/artifact paths on $(CURDIR). Guard against `cd qp-ssh &&
# make`, which would resolve them under qp-ssh/ — fail clearly instead of letting
# the include below error cryptically on a missing .env.
ifeq ($(wildcard .env),)
$(error run qp-ssh from the repo root — `make -f qp-ssh/Makefile <target>` or via Makefile.publish; .env not found in $(CURDIR))
endif

include .env

BUILD_DIR := $(CURDIR)/.build
include Makefile.commons

VERSION := $(QP_VERSION)

# Per-run logs: ONE timestamped file per kind under .logs/ (gitignored), fixed at parse
# time so every target in a single `make` invocation shares it. Smoke recipes start with
# `@$(LOG)` (-> smoke-*.log), stress recipes with `@$(SLOG)` (-> stress-*.log); each tees
# its stdout+stderr to its log (and to the console).
TS         := $(shell date -u +%Y%m%dT%H%M%SZ)
LOG_FILE   := .logs/smoke-qpssh-$(TS).log
STRESS_LOG := .logs/stress-qpssh-$(TS).log
LOG  = mkdir -p $(dir $(LOG_FILE))   ; exec > >(tee -a "$(LOG_FILE)") 2>&1   ; printf '\n=== %s @ %s ===\n' "$@" "$$(date -u +%FT%TZ)"
SLOG = mkdir -p $(dir $(STRESS_LOG)) ; exec > >(tee -a "$(STRESS_LOG)") 2>&1 ; printf '\n=== %s @ %s ===\n' "$@" "$$(date -u +%FT%TZ)"

# -----------------------------------------------------------------------------
# Build artifacts.
# -----------------------------------------------------------------------------
QP_SUITE  := $(CURDIR)/.qp/sbin/$(QP_PROGRAM_PREFIX)sshd   # marker for the built .qp tree
PAYLOAD   := $(BUILD_DIR)/payload-ssh
RPMBUILD  := $(BUILD_DIR)/rpmbuild-ssh
RPM       := $(CURDIR)/dist/qp-ssh-$(VERSION)-1.x86_64.rpm

# Toolbox build-tree smoke. The fast pre-build gate runs the UNPRIVILEGED smokes in the
# fedora toolbox against the BUILT .qp tree - no install, no host changes (mirrors
# qp-nebula/qp-stunnel). The built binaries' compiled-in absolute paths (RPATH
# $(QP_PREFIX)/lib, OpenSSL's OPENSSLDIR $(QP_PREFIX)/ssl, the qp-sshd-session libexec
# helper sshd execs) all assume the install prefix, so QP_TREELINK symlinks $(QP_PREFIX)
# -> the build tree inside the toolbox and the binaries then behave exactly as installed.
# The SELinux/systemd deployment tier runs in a real VM, not the rootless container.
QP_TREELINK := sudo ln -sfn $(CURDIR)/.qp $(QP_PREFIX)
SMOKE_ENV   := QP_PREFIX=$(QP_PREFIX) QP_PROGRAM_PREFIX=$(QP_PROGRAM_PREFIX)

# -----------------------------------------------------------------------------
# RPM endpoints — derived from the shared registry base in .env
# ($(RPM_REGISTRY_URL), $(PACKAGE_LINK_REPO)) + this component's package name, so
# qp-ssh and qp-stunnel build them identically. RPM_UPLOAD_URL + CA_CERT come from
# .env; creds are prompted (never .netrc). Delete targets the full version-RELEASE
# -----------------------------------------------------------------------------
RPM_PKG                := qp-ssh
RPM_PACKAGE_URL        := $(RPM_REGISTRY_URL)/$(RPM_PKG)
PACKAGE_LINK_URL_RPM   := $(RPM_PACKAGE_URL)/-/link/$(PACKAGE_LINK_REPO)
PACKAGE_UNLINK_URL_RPM := $(RPM_PACKAGE_URL)/-/unlink
CURL                   := curl -fsS --cacert "$(CA_CERT)"
RPM_DELETE_URL         := $(RPM_PACKAGE_URL)/$(VERSION)-1

export CA_CERT

# The shared libvirt sim (golden base + * nets + provisioning scripts) is the
# first-class simulation/ module; test-confine + stress drive it. Run from the repo root.
SIM := $(CURDIR)/simulation

STRESS_TARGETS := c_rehash openssl qp-scp qp-sftp-server qp-sftp qp-ssh-add qp-ssh-agent \
                qp-sshd-auth qp-sshd-session qp-sshd qp-ssh-keygen qp-ssh-keyscan \
                qp-ssh-keysign qp-ssh-pkcs11-helper qp-ssh qp-ssh-sk-helper
STRESS_TARGETS := $(addprefix stress-,$(STRESS_TARGETS))

DEPLOY_DIR := $(CURDIR)/deploy/qp-ssh
QP_KEY     := $(HOME)/.qp-ssh/qp-id_mldsa87

.PHONY: build payload package package-clean uninstall install publish link clean smoke \
        stress-confine stress $(STRESS_TARGETS) smoke-binaries smoke-handshake stage bootstrap

# =============================================================================
# BUILD — compile OQS-OpenSSH + liboqs + OpenSSL into .qp (slow; in toolbox).
# Built only if missing; force a full rebuild by wiping the suite build:
# `make -C qp-ssh -f Makefile.build clean` (or the component `clean` target).
# =============================================================================

build: $(QP_SUITE)
$(QP_SUITE): | $(TOOLBOX_OK)
	@echo "[build] building post-quantum OpenSSH suite into .qp (slow)"
	$(T) make -C qp-ssh -f Makefile.build build

# =============================================================================
# PAYLOAD — stage the .qp tree + the packaging files at final filesystem paths.
# =============================================================================

payload: build qp-ssh/packaging/qp-sshd_config qp-ssh/packaging/qp-ssh-uninstall.sh \
         qp-ssh/packaging/qp-sshd.service qp-ssh/packaging/qp-ssh.sysusers qp-ssh/selinux/qp_ssh.pp
	rm -rf $(PAYLOAD)
	# The whole built suite -> /usr/local/qp (mirrors install.sh.in's cp, minus
	# the dev-only activate hook whose paths point at this build host).
	mkdir -p $(PAYLOAD)/usr/local/qp
	rsync -a --exclude=activate $(CURDIR)/.qp/ $(PAYLOAD)/usr/local/qp/
	# Bake the opinionated server config + the uninstall script into the tree.
	install -D -m0644 qp-ssh/packaging/qp-sshd_config       $(PAYLOAD)/usr/local/qp/etc/qp-sshd_config
	install -D -m0755 qp-ssh/packaging/qp-ssh-uninstall.sh  $(PAYLOAD)/usr/local/qp/sbin/qp-ssh-uninstall
	# systemd unit, sysusers.d, prebuilt SELinux policy module.
	install -D -m0644 qp-ssh/packaging/qp-sshd.service  $(PAYLOAD)/etc/systemd/system/qp-sshd.service
	install -D -m0644 qp-ssh/packaging/qp-ssh.sysusers  $(PAYLOAD)/usr/lib/sysusers.d/qp-ssh.conf
	install -D -m0644 qp-ssh/selinux/qp_ssh.pp          $(PAYLOAD)/usr/share/selinux/packages/qp_ssh.pp

# Compile the SELinux module (.te + .fc -> .pp) in the toolbox if stale.
qp-ssh/selinux/qp_ssh.pp: qp-ssh/selinux/qp_ssh.te qp-ssh/selinux/qp_ssh.fc qp-ssh/selinux/Makefile | $(TOOLBOX_OK)
	$(T) make -C qp-ssh/selinux

# =============================================================================
# RPM — rpmbuild inside the toolbox. Write straight to dist/ (RPM 6.0 wipes the
# build tree right after writing, eating an rpm left in _topdir/RPMS).
# =============================================================================

$(RPM): payload qp-ssh/packaging/qp-ssh.spec | $(TOOLBOX_OK)
	rm -rf $(RPMBUILD)
	mkdir -p $(RPMBUILD)/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS} $(CURDIR)/dist
	tar -C $(PAYLOAD) -czf $(RPMBUILD)/SOURCES/qp-ssh-payload-$(VERSION).tar.gz .
	cp qp-ssh/packaging/qp-ssh.spec $(RPMBUILD)/SPECS/
	$(T) rpmbuild -bb \
	  --define "_topdir $(RPMBUILD)" \
	  --define "qp_version $(VERSION)" \
	  --define "dist %{nil}" \
	  --define "_rpmdir $(CURDIR)/dist" \
	  --define "_rpmfilename $(notdir $(RPM))" \
	  $(RPMBUILD)/SPECS/qp-ssh.spec
	@test -f $(RPM) || { echo "[package] rpm not written to $(RPM)"; exit 1; }
	# GPG-sign with the packaging key (ECDSA P-521) in the toolbox
	# (rpm-sign + gnupg2), in a throwaway GNUPGHOME so the operator's ~/.gnupg
	# stays untouched; the key carries no passphrase.
	$(T) bash -c 'set -e; export GNUPGHOME="$$(mktemp -d)"; trap "rm -rf $$GNUPGHOME" EXIT; gpg --batch --quiet --import "$(GPG_SIGN_KEY)"; rpmsign --addsign --define "_gpg_name $(GPG_SIGN_NAME)" "$(RPM)"'
	# Confirm a signature is present. rpm -Kv reports it even when the key isn't
	# imported ('NOKEY'); capture since -K exits non-zero then, and the wording
	# shifts with import state ('key ID …: NOKEY' vs 'key fingerprint …: OK').
	@sig="$$(rpm -Kv $(RPM) 2>&1 || true)"; echo "$$sig" | grep -qiE 'signature, key (id|fingerprint)' || { echo "[package] signing FAILED — $(RPM) is unsigned:"; echo "$$sig"; exit 1; }
	@echo "[package] built + signed $(RPM)"

# =============================================================================
# PACKAGE — rpm build (no install).
# =============================================================================

package:
	@echo "[package] clean build of $(notdir $(RPM))"
	$(MAKE) -f qp-ssh/Makefile $(RPM)

package-clean: clean package

# =============================================================================
# UNINSTALL — full system teardown via the shipped uninstall script. Idempotent: a
# no-op when nothing is installed (the script self-elevates + tolerates absent state).
# Chained into install so the %post host-key generation + SELinux load run fresh.
# =============================================================================
uninstall:
	@echo "[uninstall] qp-ssh system teardown (idempotent)"
	sudo bash qp-ssh/packaging/qp-ssh-uninstall.sh || true

# =============================================================================
# INSTALL — deploy the built rpm + smoke (re-runnable). Uninstalls first so the
# %post host-key generation + SELinux load run fresh.
# =============================================================================

install:
	@test -f $(RPM) || { echo "[install] no rpm at $(RPM) — run 'make -f qp-ssh/Makefile package' first"; exit 1; }
	# Import the packaging pubkey + verify the signature BEFORE tearing down any
	# existing install (gpgcheck on proves the sign chain end-to-end locally).
	sudo rpm --import $(GPG_SIGN_CERT)
	rpm -K $(RPM) | grep -qi 'signatures OK' || { echo "[install] signature verify FAILED:"; rpm -K $(RPM); exit 1; }
	@echo "[install] uninstall -> dnf install"
	$(MAKE) -f qp-ssh/Makefile uninstall
	sudo dnf install -y --setopt=localpkg_gpgcheck=1 $(RPM)
	@echo "[install] waiting for qp-sshd on :$(QP_PORT)"
	for i in $$(seq 1 60); do
	  ss -H -tln 2>/dev/null | grep -q ":$(QP_PORT) " && break
	  sleep 1
	done
	@echo "[install] PASS"

# =============================================================================
# PUBLISH — ship the ALREADY-BUILT rpm. No build prereqs. Delete the existing
# upstream version (no-op if absent), then upload.
# =============================================================================

publish:
	@test -f "$(RPM)" || { echo "[publish] missing $(RPM) — run 'make -f qp-ssh/Makefile package' first"; exit 1; }
	@sig="$$(rpm -Kv "$(RPM)" 2>&1 || true)"; echo "$$sig" | grep -qiE 'signature, key (id|fingerprint)' || { echo "[publish] $(RPM) is unsigned — run 'make -f qp-ssh/Makefile package' (it signs)"; exit 1; }
	@echo "[publish] credentials for the RPM registry (write-capable account)"
	read -rp "  username: " u
	read -rsp "  access token: " t; echo
	echo "[publish] qp-ssh $(VERSION) -> RPM registry"
	$(CURL) -H "Authorization: token $$t" -X DELETE "$(RPM_DELETE_URL)" >/dev/null 2>&1 || true
	$(CURL) -H "Authorization: token $$t" -X PUT --upload-file "$(RPM)" "$(RPM_UPLOAD_URL)"
	echo "[publish] uploaded qp-ssh $(VERSION)"

# =============================================================================
# LINK (DEFAULT) — publish, then link the rpm package to repository
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
# build intermediates. Keeps the toolbox AND the expensive .qp suite build.
# =============================================================================

clean:
	@echo "[clean] system teardown via the shipped uninstall script"
	sudo bash qp-ssh/packaging/qp-ssh-uninstall.sh || true
	@echo "[clean] wiping the qp-ssh suite build (forces a full rebuild) + rpm intermediates"
	$(MAKE) -C qp-ssh -f Makefile.build clean
	rm -rf $(PAYLOAD) $(RPMBUILD) $(RPM)
	@echo "[clean] done (toolbox kept)"
# =============================================================================
# SMOKE (toolbox) — the fast pre-build gate: every vended binary loads + runs, and a
# full post-quantum handshake (mlkem1024-sha384 + ssh-mldsa-87) completes against a
# qp-sshd we spawn ourselves on a loopback port. Runs UNPRIVILEGED in the toolbox
# against the BUILT tree - no install, no systemd, no SELinux (mirrors qp-nebula /
# qp-stunnel). The installed + SELinux-confined deployment is validated by stress-confine.
# =============================================================================

smoke: smoke-binaries smoke-handshake
	@$(LOG)
	@echo "[smoke] PASS"

# =============================================================================
# STRESS-CONFINE (deployment tier, libvirt sim) — the checks that need a REAL installed,
# systemd-run, SELinux-enforcing system (the daemon is listening, a login session
# transitions out of qp_sshd_t, the unit drops CAP_SYS_ADMIN, the preauth helper carries
# the isolated entrypoint, a handshake raises zero AVC denials). A rootless toolbox can
# neither load SELinux policy nor run systemd units, so this runs in a clean-room VM:
# boots one confine VM via the shared simulation/ harness, dnf-installs the qp-ssh rpm,
# and runs qp-ssh/scripts/test-confine.sh in it. Part of `stress` (the VM deployment tier).
# =============================================================================
stress-confine: $(RPM)
	@$(SLOG)
	@echo "[stress] qp-ssh deployment-tier confine checks (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="mgmt node" provision-key base
	RUNNER_RPMS='$(RPM)' \
	RUNNER_CHECK='$(CURDIR)/qp-ssh/scripts/test-confine.sh' \
	RUNNER_ENV='QP_PREFIX=$(QP_PREFIX) QP_PORT=$(QP_PORT) QP_PROGRAM_PREFIX=$(QP_PROGRAM_PREFIX)' \
	DOM_PREFIX=qpssh QPN_SUFFIX=-stress-confine $(SIM)/scripts/runner.sh $(SIM)/inventory/runner.env

# =============================================================================
# STRESS (deployment tier, libvirt sim) — elaborate per-tool user-story tests: each
# qp-ssh/scripts/test-<tool>.sh drives a vended binary the way a user would, against our
# opinionated PQ defaults (daemon-spawned helpers exercised via the client op that invokes
# them, the path asserted through the journal). Every tool gets its OWN stress-<tool> leaf
# that boots a clean-room VM via runner.sh (real systemd + SELinux), dnf-installs the rpm,
# and runs that one test in it (_common.sh + siblings ride along via the dir push); `stress`
# chains them all. The leaves are generated from STRESS_TARGETS, so adding a test-<tool>.sh is
# a one-line change here.
# =============================================================================
stress: stress-confine $(STRESS_TARGETS)
	@$(SLOG)
	@echo "[stress] PASS ($(words $(STRESS_TARGETS)) tools)"

define STRESS_RULE
stress-$(1): $$(RPM)
	@$$(SLOG)
	@echo "[stress] qp-ssh $(1) user-story test (libvirt sim)"
	$$(MAKE) -C $$(SIM) nets NETS="mgmt node" provision-key base
	RUNNER_RPMS='$$(RPM)' \
	RUNNER_CHECK='$$(CURDIR)/qp-ssh/scripts/test-$(1).sh' \
	RUNNER_ENV='QP_PREFIX=$$(QP_PREFIX) QP_PORT=$$(QP_PORT) QP_PROGRAM_PREFIX=$$(QP_PROGRAM_PREFIX)' \
	DOM_PREFIX=qpssh QPN_SUFFIX=-stress-$(1) $$(SIM)/scripts/runner.sh $$(SIM)/inventory/runner.env
endef
$(foreach t,$(STRESS_TARGETS),$(eval $(call STRESS_RULE,$(t))))

# Every vended ELF executable must resolve its shared libs (the bundled openssl/
# liboqs via rpath — the exact class of bug that left qp-sshd unable to map
# libcrypto) AND execute. ldd proves resolution; a -V probe proves it runs (a
# usage/"unknown option" reply still means it ran — only a loader error, rc 127,
# or a hang is a failure). Covers client tools, the daemon, openssl, and the
# libexec helpers; the shell uninstall script (non-ELF) is skipped.
smoke-binaries: $(QP_SUITE) | $(TOOLBOX_OK)
	@$(LOG)
	@echo "[smoke] all vended binaries load their libs + execute (toolbox, build tree)"
	$(T) $(QP_TREELINK)
	$(T) bash -c 'cd $(CURDIR) && $(SMOKE_ENV) bash qp-ssh/scripts/test-binaries.sh'

# Full PQ handshake in the toolbox against a qp-sshd we spawn ourselves on a loopback
# port (no install, no systemd): mlkem1024-sha384 KEX + ssh-mldsa-87 host key & client
# pubkey auth + a session command, asserting the negotiated KEX. Exercises the built
# binaries (sshd, ssh, ssh-keygen, the sshd-session helper) end to end. See
# qp-ssh/scripts/test-handshake.sh. The SELinux session-domain transition is asserted in
# the VM tier, where the daemon runs confined under systemd.
smoke-handshake: $(QP_SUITE) | $(TOOLBOX_OK)
	@$(LOG)
	@echo "[smoke] loopback PQ handshake in the toolbox (self-spawned qp-sshd)"
	$(T) $(QP_TREELINK)
	$(T) bash -c 'cd $(CURDIR) && $(SMOKE_ENV) bash qp-ssh/scripts/test-handshake.sh'

# =============================================================================
# OPERATOR DEV / ONBOARDING (non-RPM) — build the suite, stage a self-contained
# bundle, then scp+install it onto a host over plain SSH and authorize the
# operator's PQ key. The rpm reproduces install.sh.in for repo-enabled hosts;
# this is the bootstrap transport for a host that doesn't yet have the rpm
# repo. Moved here from the old root Makefile; builds via the component build.
# =============================================================================
stage: $(QP_SUITE)
	@echo "[stage] $(DEPLOY_DIR)"
	rm -rf $(DEPLOY_DIR)
	mkdir -p $(DEPLOY_DIR)/payload
	# Mirror the local build into payload/, minus the dev-only activate
	# hook (its absolute paths point at this build host, not the target).
	# qp-ssh's build target sets QP_PREFIX=$$(PWD)/.qp, but $$(PWD) under
	# `make -C qp-ssh` inherits from this parent invocation, so the build
	# tree lives at $(CURDIR)/.qp — not qp-ssh/.qp.
	rsync -a --exclude=activate $(CURDIR)/.qp/ $(DEPLOY_DIR)/payload/
	# Bake configuration into install.sh.
	sed \
	    -e 's|__QP_PREFIX__|$(QP_PREFIX)|g' \
	    -e 's|__QP_PORT__|$(QP_PORT)|g' \
	    -e 's|__QP_PROGRAM_PREFIX__|$(QP_PROGRAM_PREFIX)|g' \
	    qp-ssh/install.sh.in > $(DEPLOY_DIR)/install.sh
	chmod +x $(DEPLOY_DIR)/install.sh
	@echo "[stage] ready: $(DEPLOY_DIR)"

# ── Operator's PQ client key ──────────────────────────────────
# Personal post-quantum signature keypair used to qp-ssh into hosts
# bootstrapped by this operator. Sentinel'd on the private-key path:
# generated once with the locally-built ssh-keygen, then reused for
# every subsequent bootstrap. Remove ~/.qp-ssh/qp-id_mldsa87* to
# regenerate. The build-time paths patch makes ~/.qp-ssh the default
# user dir, so `qp-ssh user@host` (no -i) will find this identity.
$(QP_KEY): $(QP_SUITE)
	@mkdir -p $(HOME)/.qp-ssh
	@chmod 700 $(HOME)/.qp-ssh
	@echo "[qp-key] generating $(QP_KEY)"
	$(CURDIR)/.qp/bin/$(QP_PROGRAM_PREFIX)ssh-keygen -t ssh-mldsa-87 -f $(QP_KEY) -N ""

# ── Bootstrap qp-ssh on any IP ────────────────────────────────
# scp the deploy bundle + the operator's PQ pubkey, then ssh in and
# (1) run install.sh and (2) append the pubkey to
# ~/.qp-ssh/authorized_keys (matching the AuthorizedKeysFile
# directive in the generated sshd_config). The remote script is fed
# via stdin to `bash -s` (heredoc); quoted REMOTE marker prevents
# local-side variable expansion.
bootstrap: stage $(QP_KEY)
	@[ -n "$(IP)" ]   || { echo "usage: make -f qp-ssh/Makefile bootstrap IP=10.1.1.5 USER=ubuntu KEY=~/.ssh/provision"; exit 1; }
	@[ -n "$(USER)" ] || { echo "usage: make -f qp-ssh/Makefile bootstrap IP=10.1.1.5 USER=ubuntu KEY=~/.ssh/provision"; exit 1; }
	@[ -n "$(KEY)" ]  || { echo "usage: make -f qp-ssh/Makefile bootstrap IP=10.1.1.5 USER=ubuntu KEY=~/.ssh/provision"; exit 1; }
	scp -i $(KEY) -o StrictHostKeyChecking=no -r $(DEPLOY_DIR) $(USER)@$(IP):/tmp/qp-ssh
	scp -i $(KEY) -o StrictHostKeyChecking=no $(QP_KEY).pub $(USER)@$(IP):/tmp/qp_authorized.pub
	# install.sh needs root → run via sudo with -tt so the password prompt
	# binds to our local terminal. Single command string (no heredoc) keeps
	# stdin free for sudo to read the password.
	ssh -tt -i $(KEY) -o StrictHostKeyChecking=no $(USER)@$(IP) sudo bash /tmp/qp-ssh/install.sh
	# authorized_keys lives in $(USER)'s own home → no sudo, heredoc on
	# stdin is fine.
	ssh -i $(KEY) -o StrictHostKeyChecking=no $(USER)@$(IP) bash -s <<-'REMOTE'
		set -euo pipefail
		mkdir -p ~/.qp-ssh && chmod 700 ~/.qp-ssh
		touch ~/.qp-ssh/authorized_keys && chmod 600 ~/.qp-ssh/authorized_keys
		grep -qxFf /tmp/qp_authorized.pub ~/.qp-ssh/authorized_keys \
		    || cat /tmp/qp_authorized.pub >> ~/.qp-ssh/authorized_keys
		rm -f /tmp/qp_authorized.pub
	REMOTE
	@echo
	@echo "qp-ssh deployed to $(IP):$(QP_PORT)"
	@echo "  qp-ssh -p $(QP_PORT) $(USER)@$(IP)"
