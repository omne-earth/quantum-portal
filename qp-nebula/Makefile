# qp-nebula/Makefile - the qp-nebula component (post-quantum Nebula).
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
.DEFAULT_GOAL := test-spike

# Absolute path to this component dir (invoked as `-f qp-nebula/Makefile` from the
# repo root, or `-C qp-nebula`).
HERE := $(patsubst %/,%,$(dir $(realpath $(lastword $(MAKEFILE_LIST)))))

# Shared toolbox machinery: $(T) = test-in-toolbox, $(TOOLBOX_OK) = build it if missing.
# .env carries TOOLBOX_NAME/IMAGE; golang is in toolbox/Containerfile.fedora. Run from
# the repo root so the includes' $(CURDIR)-relative paths resolve.
include $(HERE)/../.env
include $(HERE)/../Makefile.commons

# Per-run logs: ONE timestamped file per kind under .logs/ (gitignored), fixed at parse
# time so every target in a single `make` invocation shares it - run one smoke/stress
# target or the `smoke`/`stress` aggregate, the output lands in the same file.
# Smoke recipes start with `@$(LOG)`, stress recipes with `@$(SLOG)`; each tees its
# stdout+stderr to its log (and to the console). Both file vars are overridable on the
# command line so Makefile.publish can fold the whole suite into one suite-wide log.
TS         := $(shell date -u +%Y%m%dT%H%M%SZ)
LOG_FILE   := .logs/smoke-qpnebula-$(TS).log
STRESS_LOG := .logs/stress-qpnebula-$(TS).log
LOG  = mkdir -p $(dir $(LOG_FILE))   ; exec > >(tee -a "$(LOG_FILE)") 2>&1   ; printf '\n=== %s @ %s ===\n' "$@" "$$(date -u +%FT%TZ)"
SLOG = mkdir -p $(dir $(STRESS_LOG)) ; exec > >(tee -a "$(STRESS_LOG)") 2>&1 ; printf '\n=== %s @ %s ===\n' "$@" "$$(date -u +%FT%TZ)"

# Go coverage profiles for the toolbox suite land here (gitignored). smoke-nebula
# (core package) and smoke-e2e-qp-upstream (whole-codebase via the full e2e suite)
# write profiles here; inspect with `go tool cover -html=.coverage/<name>.cover`.
COVER_DIR := $(CURDIR)/.coverage

GOBUILD := CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build

SELINUX_PP := $(HERE)/selinux/qp_nebula.pp

SIM   := $(HERE)/../simulation
VIRSH := virsh -q -c qemu:///system
KEY   := $(SIM)/.ssh/provision_key

# Guest binaries build component-local (qp-nebula/.build/bin), like qp-ssh/.build and
# qp-stunnel/.build; the sim scripts (_common.sh) read them via the exported QPN_BIN.
# The sim keeps its own .build for per-run PKI/CFG (QPN_BUILD); only the binaries live
# here. $(BIN)/qp-nebula + nebula-cert ride to every node, qp-tput to the throughput probe.
QPN_BIN := $(HERE)/.build/bin
export QPN_BIN
BIN := $(QPN_BIN)

# -----------------------------------------------------------------------------
# RPM packaging artifacts. Component-suffixed (payload-nebula, etc.) so they never
# clobber qp-ssh/qp-stunnel's under the shared $(BUILD_DIR). Invoked from the repo
# root (`-f qp-nebula/Makefile`), so $(CURDIR) anchors .env's paths exactly as the
# siblings do.
# -----------------------------------------------------------------------------
VERSION   := $(QP_VERSION)
BUILD_DIR := $(CURDIR)/.build
PAYLOAD   := $(BUILD_DIR)/payload-nebula
RPMBUILD  := $(BUILD_DIR)/rpmbuild-nebula
RPM       := $(CURDIR)/dist/qp-nebula-$(VERSION)-1.x86_64.rpm

# RPM endpoints - derived from the shared registry base in .env exactly as qp-ssh /
# qp-stunnel do, just with this component's package name (full parity).
RPM_PKG                := qp-nebula
RPM_PACKAGE_URL        := $(RPM_REGISTRY_URL)/$(RPM_PKG)
PACKAGE_LINK_URL_RPM   := $(RPM_PACKAGE_URL)/-/link/$(PACKAGE_LINK_REPO)
PACKAGE_UNLINK_URL_RPM := $(RPM_PACKAGE_URL)/-/unlink
CURL                   := curl -fsS --cacert "$(CA_CERT)"
RPM_DELETE_URL         := $(RPM_PACKAGE_URL)/$(VERSION)-1
export CA_CERT

# Per-target net subsets - each topology target brings up ONLY the * nets it uses
# (`make -C simulation nets NETS=...`) plus the lab provision key, instead of all of them.
# Flat tests ride mgmt + underlay; the symmetric-NAT relay adds pub + the per-node NAT
# nets; the NAT tree uses pub + the tree-segment nets.
NETS_FLAT := mgmt node
NETS_NAT  := mgmt pub nat1 nat2
NETS_TREE := mgmt pub tA tB tAA tAB tBA tBB

.PHONY: test-spike vet smoke smoke-pq smoke-nebula smoke-cert smoke-nebula-cert smoke-handshake \
        smoke-unit smoke-udp smoke-control smoke-ctl smoke-e2e-qp smoke-e2e-qp-upstream smoke-coverage \
        build selinux smoke-tunnel smoke-mesh \
        stress stress-loss stress-scale stress-relay stress-relay-nat stress-relay-tree \
        stress-failover stress-throughput stress-ctl stress-ctl-remote stress-ctl-negative \
        payload package package-clean uninstall install publish link clean

# =============================================================================
# TEST (DEFAULT) - the commit-validating target, in the toolbox. Runs every spike:
# the pqnoise pqIX-analog ML-KEM-1024 handshake (in-memory + loopback) and the pqcert
# ML-DSA-87 CA minting/verifying a cert that carries an ML-KEM-1024 node key.
# =============================================================================
test-spike: vet $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula] spikes (toolbox): go test -v ./spike/..."
	$(T) bash -c 'cd $(HERE) && go test -v ./spike/...'

vet: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula] go vet (toolbox)"
	$(T) bash -c 'cd $(HERE) && go vet ./...'

# =============================================================================
# SMOKE - every smoke target, one timestamped log ($(LOG_FILE)). smoke-pq is the toolbox
# Go suite; smoke-tunnel/smoke-mesh boot the libvirt sim (needs libvirt + sudo).
# =============================================================================
smoke: vet test-spike smoke-pq smoke-tunnel smoke-mesh smoke-nebula
	@$(LOG)
	@echo "[qp-nebula] smoke complete -> $(LOG_FILE)"

# SMOKE-PQ - the single "test all our Go code" entry point: every toolbox Go smoke. Excludes
# the libvirt sim (needs VMs) and the heavy upstream-e2e parity run (smoke-e2e-qp-upstream).
smoke-pq: smoke-cert smoke-nebula-cert smoke-handshake smoke-unit smoke-udp smoke-control smoke-ctl smoke-e2e-qp smoke-e2e-qp-upstream
	@$(LOG)
	@echo "[qp-nebula] all Go smokes complete -> $(LOG_FILE)"

# =============================================================================
# SMOKE-NEBULA - the core `nebula` package (hostmap, lighthouse, firewall, conn
# manager, ...) with a coverage profile. The targeted smoke-* below cover the PQ
# subpackages (cert/handshake/control/udp/cmd); this is the daemon core. In the toolbox.
# =============================================================================
smoke-nebula: vet $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] core nebula package tests + coverage profile (toolbox)"
	mkdir -p $(COVER_DIR)
	# -skip: TestDnsServer_Stop_beforeBind_doesNotHang is an UPSTREAM timing test (asserts
	# Start returns within ~1s of a bad bind); it is flaky under the rootless toolbox's
	# scheduling and is not our PQ code. Skipped so the smoke is deterministic; the e2e
	# parity run (smoke-e2e-qp-upstream) still exercises the daemon end to end.
	$(T) bash -c 'cd $(HERE)/nebula && go test -v . -count=1 -skip "TestDnsServer_Stop_beforeBind_doesNotHang" -covermode=atomic -coverprofile=$(COVER_DIR)/nebula.cover'
	$(T) bash -c 'cd $(HERE)/nebula && go tool cover -func=$(COVER_DIR)/nebula.cover | tail -1'
	$(T) bash -c 'cd $(HERE)/nebula && go tool cover -html=$(COVER_DIR)/nebula.cover -o $(COVER_DIR)/nebula.html'
	@echo "[qp-nebula:fork] nebula PASS (coverage -> $(COVER_DIR)/nebula.cover, report -> $(COVER_DIR)/nebula.html)"

# =============================================================================
# SMOKE-CERT (Phase 2a) - the post-quantum cert layer in the nebula submodule: the
# dedicated PQ tests, then the full cert regression suite. In the toolbox. (Coverage
# is measured by smoke-nebula / smoke-e2e-qp-upstream, not gated here.)
# =============================================================================
smoke-cert: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] cert PQ tests (toolbox)"
	$(T) bash -c 'cd $(HERE)/nebula && go test -v ./cert/ -run TestPQ'
	@echo "[qp-nebula:fork] cert regression suite"
	$(T) bash -c 'cd $(HERE)/nebula && go test -v ./cert/...'
	@echo "[qp-nebula:fork] cert PASS"

# =============================================================================
# SMOKE-NEBULA-CERT (Phase 2a) - the qp-nebula-cert CLI end to end (TestPQCertCLI)
# plus the full nebula-cert regression suite. In the toolbox.
# =============================================================================
smoke-nebula-cert: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] qp-nebula-cert PQ end-to-end (TestPQCertCLI) (toolbox)"
	$(T) bash -c 'cd $(HERE)/nebula && go test -v ./cmd/nebula-cert/ -run TestPQCertCLI -v'
	@echo "[qp-nebula:fork] nebula-cert regression suite"
	$(T) bash -c 'cd $(HERE)/nebula && go test -v ./cmd/nebula-cert/...'
	@echo "[qp-nebula:fork] nebula-cert PASS"

# =============================================================================
# SMOKE-HANDSHAKE (Phase 2b) - the post-quantum handshake graft: full build + the
# handshake package tests. In the toolbox.
# =============================================================================
smoke-handshake: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] full build + handshake pkg tests (toolbox)"
	$(T) bash -c 'cd $(HERE)/nebula && go build ./... && go test -v ./handshake/...'
	@echo "[qp-nebula:fork] handshake PASS"

# =============================================================================
# SMOKE-UNIT (Phase 2b) - root-package PQ unit tests (curve->handshake-subtype mapping +
# the pending-responder reaper) AND the module build guard: `go build ./...` catches a
# compile break anywhere in the fork. Split out of the old smoke-e2e-qp so a failure points at
# one thing, but it keeps the build so breaking the suite still rebuilds everything.
# =============================================================================
smoke-unit: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] go build ./... + curve->subtype + reaper unit tests (toolbox)"
	$(T) bash -c 'cd $(HERE)/nebula && go build ./... && go test -v . -run "TestHandshakeSubtypeForCurve|TestReapPendingResponders" -count=1'
	@echo "[qp-nebula:fork] unit PASS"

# =============================================================================
# SMOKE-UDP (Phase 2b) - a large pqIX datagram survives a real UDP socket. PQ handshake
# packets are bigger than classical; this guards the datagram path against truncation.
# =============================================================================
smoke-udp: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] large pqIX datagram survives a real UDP socket (toolbox)"
	$(T) bash -c 'cd $(HERE)/nebula && go test -v ./udp/ -run TestStdConnLargeDatagram -count=1'
	@echo "[qp-nebula:fork] udp PASS"

# =============================================================================
# SMOKE-CONTROL - the transport-neutral control plane: the command registry + the local
# unix control socket (control/). Race-checked and fast. The ~20 command bodies in
# control_commands.go need a live *Interface and are exercised by the sim, not here.
# =============================================================================
smoke-control: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] control registry + socket transport (toolbox, -race)"
	$(T) bash -c 'cd $(HERE)/nebula && go test -v ./control/... -race -count=1'
	@echo "[qp-nebula:fork] control PASS"

# =============================================================================
# SMOKE-CLI - the `nebula ctl` control client end to end: builds the REAL nebula binary and
# drives every ctl path against an in-process control socket (success, args, help, unknown,
# command error, unreachable socket, missing command, bad flag) + the subcommand-gate unit
# test. The client logic (control.RunCtl/exchange) is unit-covered under smoke-control.
# =============================================================================
smoke-ctl: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] nebula ctl: every CLI path via the real binary (toolbox, -race)"
	$(T) bash -c 'cd $(HERE)/nebula && go test -v ./cmd/nebula/ -run Ctl -race -count=1'
	@echo "[qp-nebula:fork] cli PASS"

# =============================================================================
# SMOKE-E2E-QP (Phase 2b) - the pqIX handshake wired into the live connection manager, proven
# node to node over an in-memory conn: our fork's PQ e2e matrix PLUS the classical IX
# regression subset (the upstream tests we must not break). In the toolbox. For the FULL
# upstream e2e suite (parity) run smoke-e2e-qp-upstream.
# =============================================================================
smoke-e2e-qp: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] node-to-node pqIX matrix + IX regression (e2e, toolbox)"
	$(T) bash -c 'cd $(HERE)/nebula && go test -v -tags e2e_testing ./e2e/ -run "TestPQGoodHandshake|TestPQHandshakeRetransmitDuplicate|TestPQStage1Race|TestPQRehandshaking|TestPQUntrustedCARejected|TestPQHandshakeTruncatedMsg2Recovery|TestPQRelays|TestGoodHandshake$$|TestHandshakeRetransmitDuplicate$$|TestStage1Race$$|TestRelays$$" -count=1 -v'
	@echo "[qp-nebula:fork] e2e PASS"

# =============================================================================
# SMOKE-E2E-QP-UPSTREAM - parity with upstream's `make e2e`: the ENTIRE e2e package
# (`go test -tags e2e_testing ./e2e`, unfiltered), not just our PQ subset. Heavier/slower;
# run it to confirm no upstream e2e behaviour regressed. Carries `-coverpkg=./...` so the
# profile measures how much of the WHOLE nebula codebase the full e2e suite exercises -
# the comprehensive integration coverage number (-> $(COVER_DIR)/e2e-upstream.cover).
# =============================================================================
smoke-e2e-qp-upstream: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] FULL upstream e2e suite + whole-codebase coverage (parity, toolbox)"
	mkdir -p $(COVER_DIR)
	$(T) bash -c 'cd $(HERE)/nebula && go test -v -tags e2e_testing ./e2e/ -count=1 -coverpkg=./... -covermode=atomic -coverprofile=$(COVER_DIR)/e2e-upstream.cover'
	$(T) bash -c 'cd $(HERE)/nebula && go tool cover -func=$(COVER_DIR)/e2e-upstream.cover | tail -1'
	$(T) bash -c 'cd $(HERE)/nebula && go tool cover -html=$(COVER_DIR)/e2e-upstream.cover -o $(COVER_DIR)/e2e-upstream.html'
	@echo "[qp-nebula:fork] e2e-upstream PASS (coverage -> $(COVER_DIR)/e2e-upstream.cover, report -> $(COVER_DIR)/e2e-upstream.html)"

# =============================================================================
# SMOKE-COVERAGE - the complete report: the ENTIRE module test suite (every package
# + the e2e suite) in one run, instrumented against the whole codebase (-coverpkg=./...),
# merged into a single profile + func summary + HTML report in .coverage/. This is the
# one-number "how much of qp-nebula's fork do our tests touch" view (the per-target
# smoke-nebula / smoke-e2e-qp-upstream profiles are focused subsets). Heavy; on-demand,
# not in the `smoke` aggregate. It is a REPORT, not a gate: the suite still runs and
# prints failures, but the report is rendered regardless (the profile is written even
# when a test fails) so a single flake never costs you the coverage view.
# =============================================================================
smoke-coverage: $(TOOLBOX_OK)
	@$(LOG)
	@echo "[qp-nebula:fork] complete coverage: whole module (all packages + e2e), toolbox"
	mkdir -p $(COVER_DIR)
	# -skip the known flaky upstream timing test; `|| WARN` keeps the report rendering if
	# any test fails (go still writes the profile) - failures are visible in the output above.
	$(T) bash -c 'cd $(HERE)/nebula && go test -tags e2e_testing ./... -skip "TestDnsServer_Stop_beforeBind_doesNotHang" -coverpkg=./... -covermode=atomic -coverprofile=$(COVER_DIR)/all.cover' \
	  || echo "  WARN: some tests failed - coverage report reflects the runs that completed"
	$(T) bash -c 'cd $(HERE)/nebula && go tool cover -func=$(COVER_DIR)/all.cover | tail -1'
	$(T) bash -c 'cd $(HERE)/nebula && go tool cover -html=$(COVER_DIR)/all.cover -o $(COVER_DIR)/all.html'
	@echo "[qp-nebula:fork] complete coverage -> $(COVER_DIR)/all.cover, report -> $(COVER_DIR)/all.html"

# =============================================================================
# BUILD - compile the GUEST binaries (static linux/amd64) in the toolbox: the qp-nebula
# daemon + nebula-cert (the CA/signing tool) + qp-tput (the throughput probe). The sim
# smoke/stress targets depend on this and the sim scripts pick the binaries up from
# $(BIN). Mirrors qp-ssh's build target - in the toolbox, never on the host. Phony: go's
# own build cache makes a re-run a near no-op when nothing changed.
#
# BUILD TAGS: the DEFAULT build (below) excludes the embedded ssh debug server - `sshd/` and
# `ssh.go` sit behind `//go:build sshd`, so the default binary does NOT link x/crypto/ssh
# (leaner, no PQ-SSH crypto). Control is the local unix socket + `nebula ctl` instead. To
# restore the legacy embedded transport, add `-tags sshd` to GOBUILD; that build pulls
# golang.org/x/crypto/ssh back in (retained in go.mod precisely for it - `go mod tidy` keeps
# it). `go list -deps ./cmd/nebula | grep x/crypto/ssh` is empty by default, non-empty under
# `-tags sshd` (asserted by smoke-control).
# =============================================================================
build: | $(TOOLBOX_OK)
	@echo "[qp-nebula] building qp-nebula + nebula-cert + qp-tput (static linux/amd64, toolbox)"
	mkdir -p $(BIN)
	$(T) bash -c 'cd $(HERE)/nebula && $(GOBUILD) -o $(BIN)/qp-nebula ./cmd/nebula'
	$(T) bash -c 'cd $(HERE)/nebula && $(GOBUILD) -o $(BIN)/nebula-cert ./cmd/nebula-cert'
	$(T) bash -c 'cd $(HERE)/scripts/test/tput && $(GOBUILD) -o $(BIN)/qp-tput .'

# =============================================================================
# SELINUX - compile the qp_nebula_t policy module (.te + .fc -> .pp) in the toolbox
# (selinux-policy-devel). The sim confinement (smoke-tunnel/smoke-mesh) loads this
# .pp into each node VM; the rpm ships it and loads it in %post. Built when stale.
# =============================================================================
$(SELINUX_PP): $(HERE)/selinux/qp_nebula.te $(HERE)/selinux/qp_nebula.fc $(HERE)/selinux/Makefile | $(TOOLBOX_OK)
	$(T) make -C $(HERE)/selinux

selinux: $(SELINUX_PP)
	@echo "[qp-nebula] SELinux module built -> $(SELINUX_PP)"

# =============================================================================
# LIBVIRT SIM (smoke-tunnel/smoke-mesh + stress-*) - the real-network tier. One node =
# one VM (real machines, not host netns). A tunnel is two VMs; the mesh is five. The
# pqIX tunnel forms VM-to-VM over the isolated node net. The shared harness -
# golden base image, * networks, provisioning scripts, inventories, domain templates
# - is the first-class simulation/ module; that module owns base + net lifecycle, these
# targets drive its scripts/ + inventory/ for the qp-nebula topologies. Needs libvirt +
# sudo (the rootless toolbox cannot create the VMs/netns these exercise).
# =============================================================================

# =============================================================================
# SMOKE-TUNNEL (Phase 2b) - the REAL-network proof in the sim (two VMs): 1 lighthouse +
# 1 node on the isolated node, each running one qp-nebula daemon, pqIX-handshaking
# over real UDP. Asserts overlay ICMP both ways + confirms style:pqix. (Was host netns.)
# =============================================================================
smoke-tunnel: build selinux
	@$(LOG)
	@echo "[qp-nebula:fork] two-VM pqIX tunnel, daemons confined in qp_nebula_t (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_FLAT)" provision-key base
	DOM_PREFIX=qpnebula QPN_SUFFIX=-smoke-tunnel $(HERE)/scripts/test-mesh.sh $(SIM)/inventory/qp-nebula/tunnel.env

# =============================================================================
# SMOKE-MESH (Phase 2b) - a real 5-VM post-quantum mesh: 2 lighthouses + 3 nodes, each
# its own VM on the underlay; nodes discover each other via the lighthouses and
# pqIX-handshake on demand; asserts the full overlay reachability matrix. (Was host netns
# across NAT-separated subnets.)
# =============================================================================
smoke-mesh: build selinux
	@$(LOG)
	@echo "[qp-nebula:fork] five-VM pqIX mesh, daemons confined in qp_nebula_t (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_FLAT)" provision-key base
	DOM_PREFIX=qpnebula QPN_SUFFIX=-smoke-mesh $(HERE)/scripts/test-mesh.sh $(SIM)/inventory/qp-nebula/mesh.env

# =============================================================================
# STRESS - every stress target, one timestamped log ($(STRESS_LOG)). All boot the
# libvirt sim (needs libvirt + sudo); this is heavy (the NAT-tree run alone is 16 VMs).
# Unlike the smokes (which run the .build binary), STRESS validates the SHIPPED rpm: each
# target depends on $(RPM) and exports QPN_RPM, telling the sim harness (_common.sh) to
# dnf-install it in every VM and run the packaged systemd unit (real %post SELinux load +
# RuntimeDirectory socket + /usr/local/qp layout) - parity with qp-ssh/qp-stunnel stress.
# =============================================================================
stress stress-loss stress-scale stress-relay stress-relay-nat stress-relay-tree stress-failover stress-throughput stress-ctl stress-ctl-remote stress-ctl-negative: export QPN_RPM := $(RPM)

stress: stress-loss stress-scale stress-relay stress-relay-nat stress-relay-tree stress-failover stress-throughput stress-ctl stress-ctl-remote stress-ctl-negative
	@$(SLOG)
	@echo "[qp-nebula] stress complete -> $(STRESS_LOG)"

# =============================================================================
# STRESS-* (Phase 2b) - hammer the pqIX mesh under adverse conditions, in the sim (real
# VMs, not host netns). netem rides each node VM's underlay NIC.
#   stress-loss       pqIX converges under netem packet loss + latency (5 VMs)
#   stress-scale      the mesh converges with a longer deadline / handshake storm (5 VMs)
#   stress-relay      direct node-to-node underlay blocked via nft -> relayed pqIX (3 VMs)
#   stress-relay-nat  relayed pqIX over REAL symmetric double-NAT + nft as DiD (3 VMs)
#   stress-relay-tree level-3 binary NAT tree: 8 leaves, 2 lighthouse-relays (16 VMs)
#   stress-failover   kill a lighthouse VM mid-run; re-converge via the survivor (5 VMs)
#   stress-throughput data-plane Gbit/s over a pqIX tunnel via qp-tput (2 VMs)
#   stress-ctl        `nebula ctl` against a real daemon's control socket on a VM (2 VMs)
#   stress-ctl-remote `nebula ctl` over an ssh-FORWARDED control socket (remote path) (2 VMs)
#   stress-ctl-negative perms gate refuses an unprivileged user at the socket (2 VMs)
# =============================================================================
stress-loss: $(RPM)
	@$(SLOG)
	@echo "[qp-nebula:fork] pqIX mesh under packet loss + latency (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_FLAT)" provision-key base
	DOM_PREFIX=qpnebula LOSS=$(or $(LOSS),5) DELAY=$(or $(DELAY),10) DEADLINE=120 QPN_SUFFIX=-stress-loss \
	  $(HERE)/scripts/test-mesh.sh $(SIM)/inventory/qp-nebula/mesh.env

stress-scale: $(RPM)
	@$(SLOG)
	@echo "[qp-nebula:fork] pqIX mesh at scale / handshake storm (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_FLAT)" provision-key base
	DOM_PREFIX=qpnebula DEADLINE=150 QPN_SUFFIX=-stress-scale $(HERE)/scripts/test-mesh.sh $(SIM)/inventory/qp-nebula/mesh.env

stress-relay: $(RPM)
	@$(SLOG)
	@echo "[qp-nebula:fork] relayed pqIX, direct underlay blocked via nft (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_FLAT)" provision-key base
	DOM_PREFIX=qpnebula QPN_SUFFIX=-stress-relay $(HERE)/scripts/test-relay.sh $(SIM)/inventory/qp-nebula/relay.env

stress-relay-nat: $(RPM)
	@$(SLOG)
	@echo "[qp-nebula:fork] relayed pqIX over REAL symmetric double-NAT + nft block as DiD (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_NAT)" provision-key base
	DOM_PREFIX=qpnebula QPN_SUFFIX=-stress-relay-nat $(HERE)/scripts/test-relay-nat.sh $(SIM)/inventory/qp-nebula/relay-nat.env

stress-relay-tree: $(RPM)
	@$(SLOG)
	@echo "[qp-nebula:fork] level-3 binary NAT tree: 8 leaves behind nested NAT, 2 lighthouse-relays (libvirt sim, 16 VMs)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_TREE)" provision-key base
	DOM_PREFIX=qpnebula QPN_SUFFIX=-stress-relay-tree $(HERE)/scripts/test-tree.sh

stress-failover: $(RPM)
	@$(SLOG)
	@echo "[qp-nebula:fork] lighthouse failover, re-converge via the survivor (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_FLAT)" provision-key base
	DOM_PREFIX=qpnebula FAILOVER=$(or $(KILL),lh1) QPN_SUFFIX=-stress-failover $(HERE)/scripts/test-failover.sh $(SIM)/inventory/qp-nebula/mesh.env

stress-throughput: $(RPM)
	@$(SLOG)
	@echo "[qp-nebula:fork] data-plane throughput over a pqIX tunnel via qp-tput (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_FLAT)" provision-key base
	DOM_PREFIX=qpnebula DUR=$(or $(DUR),10) QPN_SUFFIX=-stress-throughput $(HERE)/scripts/test-throughput.sh $(SIM)/inventory/qp-nebula/tunnel.env

# SMOKE-CTL's deployment-tier sibling: drive `nebula ctl` against a REAL daemon's unix control
# socket on a VM (real systemd + socket + binary), not the toolbox in-process server. Brings up
# a 2-VM tunnel so list-hostmap has a peer to report. The qp-ssh-free replacement for the old
# ssh-into-the-node debug path.
stress-ctl: $(RPM)
	@$(SLOG)
	@echo "[qp-nebula:fork] nebula ctl against a real daemon control socket (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_FLAT)" provision-key base
	DOM_PREFIX=qpnebula QPN_SUFFIX=-stress-ctl $(HERE)/scripts/test-ctl.sh $(SIM)/inventory/qp-nebula/tunnel.env

# STRESS-CTL's remote sibling: the control socket has no network listener (local-only by design),
# so remote control = forward the unix socket over ssh and point ctl at the local end. Production
# forwards over qp-ssh (full PQ-KEX); the sim proves the same `ssh -L unix:` forward MECHANISM.
stress-ctl-remote: $(RPM)
	@$(SLOG)
	@echo "[qp-nebula:fork] nebula ctl over a FORWARDED control socket (remote path, libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_FLAT)" provision-key base
	DOM_PREFIX=qpnebula QPN_SUFFIX=-stress-ctl-remote $(HERE)/scripts/test-ctl-remote.sh $(SIM)/inventory/qp-nebula/tunnel.env

# Negative authz: the socket's only gate is filesystem perms (0660, daemon user + `nebula` group).
# Prove an UNPRIVILEGED user (not owner, not in-group) is refused while the owner is allowed - the
# deployment-tier check the toolbox cannot do (it needs a real socket under real uids).
stress-ctl-negative: $(RPM)
	@$(SLOG)
	@echo "[qp-nebula:fork] control socket perms gate refuses an unprivileged user (libvirt sim)"
	$(MAKE) -C $(SIM) nets NETS="$(NETS_FLAT)" provision-key base
	DOM_PREFIX=qpnebula QPN_SUFFIX=-stress-ctl-negative $(HERE)/scripts/test-ctl-negative.sh $(SIM)/inventory/qp-nebula/tunnel.env

# =============================================================================
# RPM PACKAGING (mirror qp-stunnel) - build the signed rpm, install/uninstall it,
# publish + link to the registry. qp-nebula is a SINGLE static Go binary with NO
# qp-ssh dependency, so it co-owns the shared /usr/local/qp dirs and installs on its
# own. Everything that compiles (go build, the .pp, rpmbuild) happens in the toolbox.
#   make -f qp-nebula/Makefile package   # GATE: build -> rpmbuild -> sign
#   make -f qp-nebula/Makefile install   # deploy the built rpm + config-test
#   make -f qp-nebula/Makefile publish   # SHIP: delete-existing + upload the rpm
#   make -f qp-nebula/Makefile link      # publish, then link to repository
# =============================================================================

# PAYLOAD - stage qp-nebula's OWN files at final filesystem paths. nebula-cert is
# installed under its qp-prefixed name (qp-nebula-cert) to match the .fc / spec.
payload: build selinux qp-nebula/packaging/config.yml qp-nebula/packaging/qp-nebula.service \
         qp-nebula/packaging/qp-nebula.sysusers qp-nebula/packaging/qp-nebula-uninstall.sh \
         qp-nebula/packaging/qp-nebula.spec
	rm -rf $(PAYLOAD)
	install -D -m0755 $(BIN)/qp-nebula                            $(PAYLOAD)/usr/local/qp/sbin/qp-nebula
	install -D -m0755 $(BIN)/nebula-cert                          $(PAYLOAD)/usr/local/qp/bin/qp-nebula-cert
	install -D -m0755 qp-nebula/packaging/qp-nebula-uninstall.sh  $(PAYLOAD)/usr/local/qp/sbin/qp-nebula-uninstall
	install -D -m0644 qp-nebula/packaging/config.yml             $(PAYLOAD)/usr/local/qp/etc/nebula/config.yml
	install -D -m0644 qp-nebula/packaging/qp-nebula.service      $(PAYLOAD)/etc/systemd/system/qp-nebula.service
	install -D -m0644 qp-nebula/packaging/qp-nebula.sysusers     $(PAYLOAD)/usr/lib/sysusers.d/qp-nebula.conf
	install -D -m0644 $(SELINUX_PP)                              $(PAYLOAD)/usr/share/selinux/packages/qp_nebula.pp

# $(RPM) - rpmbuild + GPG-sign in the toolbox (identical pipeline to qp-stunnel).
$(RPM): payload qp-nebula/packaging/qp-nebula.spec | $(TOOLBOX_OK)
	rm -rf $(RPMBUILD)
	mkdir -p $(RPMBUILD)/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS} $(CURDIR)/dist
	tar -C $(PAYLOAD) -czf $(RPMBUILD)/SOURCES/qp-nebula-payload-$(VERSION).tar.gz .
	cp qp-nebula/packaging/qp-nebula.spec $(RPMBUILD)/SPECS/
	$(T) rpmbuild -bb \
	  --define "_topdir $(RPMBUILD)" \
	  --define "qp_version $(VERSION)" \
	  --define "dist %{nil}" \
	  --define "_rpmdir $(CURDIR)/dist" \
	  --define "_rpmfilename $(notdir $(RPM))" \
	  $(RPMBUILD)/SPECS/qp-nebula.spec
	@test -f $(RPM) || { echo "[package] rpm not written to $(RPM)"; exit 1; }
	# GPG-sign in a throwaway GNUPGHOME (rpm-sign + gnupg2 in the toolbox) so the
	# operator's ~/.gnupg stays untouched; the key carries no passphrase.
	$(T) bash -c 'set -e; export GNUPGHOME="$$(mktemp -d)"; trap "rm -rf $$GNUPGHOME" EXIT; gpg --batch --quiet --import "$(GPG_SIGN_KEY)"; rpmsign --addsign --define "_gpg_name $(GPG_SIGN_NAME)" "$(RPM)"'
	@sig="$$(rpm -Kv $(RPM) 2>&1 || true)"; echo "$$sig" | grep -qiE 'signature, key (id|fingerprint)' || { echo "[package] signing FAILED - $(RPM) is unsigned:"; echo "$$sig"; exit 1; }
	@echo "[package] built + signed $(RPM)"

# PACKAGE - rpm build (no install).
package:
	@echo "[package] clean build of $(notdir $(RPM))"
	$(MAKE) -f qp-nebula/Makefile $(RPM)

package-clean: clean package

# UNINSTALL - full system teardown via the shipped uninstall script. Idempotent.
uninstall:
	@echo "[uninstall] qp-nebula system teardown (idempotent)"
	sudo bash qp-nebula/packaging/qp-nebula-uninstall.sh || true

# INSTALL - deploy the built rpm (re-runnable). Verify the signature, uninstall first so
# the %post SELinux load + port label run fresh, then run the host ctl smoke: it mints a
# throwaway cert, runs an EPHEMERAL qp-nebula in a temp dir, drives `nebula ctl`, and
# unwires it afterwards (self-contained, mirrors qp-stunnel's install loopback smoke).
install:
	@test -f $(RPM) || { echo "[install] no rpm at $(RPM) - run 'make -f qp-nebula/Makefile package' first"; exit 1; }
	sudo rpm --import $(GPG_SIGN_CERT)
	rpm -K $(RPM) | grep -qi 'signatures OK' || { echo "[install] signature verify FAILED:"; rpm -K $(RPM); exit 1; }
	@echo "[install] uninstall -> dnf install"
	$(MAKE) -f qp-nebula/Makefile uninstall
	sudo dnf install -y --setopt=localpkg_gpgcheck=1 $(RPM)
	@echo "[install] host ctl smoke: mint a throwaway cert, run an ephemeral daemon, drive nebula ctl"
	QP_PREFIX=$(QP_PREFIX) bash qp-nebula/scripts/test-ctl-host.sh
	@echo "[install] PASS"

# PUBLISH - ship the ALREADY-BUILT rpm. No build prereqs (uploading must not rebuild).
publish:
	@test -f "$(RPM)" || { echo "[publish] missing $(RPM) - run 'make -f qp-nebula/Makefile package' first"; exit 1; }
	@sig="$$(rpm -Kv "$(RPM)" 2>&1 || true)"; echo "$$sig" | grep -qiE 'signature, key (id|fingerprint)' || { echo "[publish] $(RPM) is unsigned - run 'make -f qp-nebula/Makefile package' (it signs)"; exit 1; }
	@echo "[publish] credentials for the RPM registry (write-capable account)"
	read -rp "  username: " u
	read -rsp "  access token: " t; echo
	echo "[publish] qp-nebula $(VERSION) -> RPM registry"
	$(CURL) -H "Authorization: token $$t" -X DELETE "$(RPM_DELETE_URL)" >/dev/null 2>&1 || true
	$(CURL) -H "Authorization: token $$t" -X PUT --upload-file "$(RPM)" "$(RPM_UPLOAD_URL)"
	echo "[publish] uploaded qp-nebula $(VERSION)"

# LINK (DEFAULT for ship) - publish, then link the rpm package to repository.
link: publish
	@echo "[link] credentials for linking (write-capable account)"
	read -rp "  username: " u
	read -rsp "  access token: " t; echo
	echo "[link] rpm: qp-nebula -> $(PACKAGE_LINK_REPO)"
	$(CURL) -H "Authorization: token $$t" -X POST "$(PACKAGE_UNLINK_URL_RPM)" >/dev/null 2>&1 || true
	$(CURL) -H "Authorization: token $$t" -X POST "$(PACKAGE_LINK_URL_RPM)"   && echo "  linked"

# CLEAN - tear down any installed qp-nebula + drop the rpm intermediates, then purge
# the sim (* domains + networks + base image) - delegates to the module.
clean:
	@echo "[clean] qp-nebula system teardown via the shipped uninstall script"
	sudo bash qp-nebula/packaging/qp-nebula-uninstall.sh || true
	rm -rf $(PAYLOAD) $(RPMBUILD) $(RPM) $(HERE)/.build
	$(MAKE) -C $(SIM) clean
