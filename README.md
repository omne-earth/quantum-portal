# Quantum Portal

*quantum portal* is a collection of minimal viable set for quantum protected web.

## Features

SELinux confined post-quantum rpms for:
1. qp-ssh: admin entrypoint: owner -> machine
2. qp-stunnel: public traffic entrypoint, optionally mtls: www -> machine
3. qp-nebula: private mesh entrypoint: machine -> machine

The RPMs are designed to support parallel deployment alongside classical counterparts.

# Dependencies
> NOTE: Only tested with Fedora 44, and is highly recommended as the build host. Other linux distros should work provided podman and toolbox are installed.

1. podman: provides OCI shim
2. toolbox: provides build boxes so hosts stay clean
3. virtmanager: required in some smoke/stress tests

## Quickstart

Build and install on a local machine, Fedora 44:

### Environment

```bash
cp .env.template .env

# these values to sign the packaged rpms
# GPG_SIGN_KEY     := $(CURDIR)/certs/packaging.key
# GPG_SIGN_CERT    := $(CURDIR)/certs/packaging.crt
# GPG_SIGN_NAME    := we@omne.earth

# these values are required to publish to an rpm registry
# RPM_UPLOAD_URL   := https://your-rpm.com/path/to/rpm/upload/api
# RPM_REGISTRY_URL := https://your-rpm.com/path/to/rpm/registry/api
# RPM_REPO_KEY_URL := https://your-rpm.com/path/to/rpm/repository.key

cp .secrets.template .secrets
# these values are required for git clone operation during builds
# GIT_RO_USERNAME := your-git-read-only-user
# GIT_RO_PASSWORD := your-git-read-only-token
```

## Packaging Pre-Requisites
```bash
mkdir -p certs

# Identity for the RPM signing key — must match GPG_SIGN_NAME in your .env
GPG_SIGN_NAME="we@omne.earth"

# Mint a passphrase-less signing keypair (the package step imports it unattended)
gpg --batch --passphrase '' --quick-generate-key "$GPG_SIGN_NAME" default default never

# Export to the paths GPG_SIGN_KEY / GPG_SIGN_CERT point at in .env
gpg --export-secret-keys --armor "$GPG_SIGN_NAME" > certs/packaging.key
gpg --export --armor             "$GPG_SIGN_NAME" > certs/packaging.crt
```

### Compile
Builds inside a toolbox container so host stays clean.

Tests run inside the toolbox container, simulation tests run inside libvirt vms.
```bash
make -f Makefile.publish build
make -f Makefile.publish smoke # qp-nebula smoke requires libvirt
```

Packages an rpm with selinux confinement and your gpg signature from previous step.
```bash
make -f Makefile.publish package
```

### Install
Install rpm with verified signature. All stress tests run in a simulated libvirt environment.
```bash
make -f Makefile.publish install
make -f Makefile.publish stress
source ./.qp/activate
```

qp-sshd starts on install. However, qp-stunnel and qp-nebula installs the systemd module but does not start them. Each needs certificate provisioning first, then can be started via:
```bash
sudo systemctl start qp-stunnel
sudo systemctl start qp-nebula
```

> Smoke and stress tests are available that demonstrate some ways of how this project can be used.

### Release

Release rpm with verified signature and push to a rpm registry. Requires *RPM_\** entries in the *.env*.
```bash
make -f Makefile.publish publish
```

For registries that require explicit package linking:
```bash
make -f Makefile.publish link
```

Gitea was used to test the publish and link targets. Other git distributions may require modifications of the targets.

### Per-Package Workflow

To run the workflow per-package, simply add *-<module-name>*, or [TAB] to list available options, for instance:
```bash
# order dependent
make -f Makefile.publish build-qpssh smoke-qpssh package-qpssh install-qpssh stress-qpssh

# qpstunnel depends on qpssh's ssl, i.e. build-qpssh
make -f Makefile.publish build-qpssh build-qpstunnel smoke-qpstunnel package-qpstunnel install-qpstunnel stress-qpstunnel

# self contained
make -f Makefile.publish build-qpnebula smoke-qpnebula package-qpnebula install-qpnebula stress-qpnebula
```

## Comments
This project is a humble effort in response to:

1. CNSA 2.0 - https://media.defense.gov/2025/May/30/2003728741/-1/-1/0/CSA_CNSA_2.0_ALGORITHMS.PDF
2. CMMC 2.0 - https://www.cisa.gov/resources-tools/resources/cybersecurity-maturity-model-certification-20-program

We at **omne** present our gratitude to the sources and projects from around the world that have been used to make *quantum-portal* possible and hope that the post-quantum migration goes smoothly.

## Disclaimer

The code is provided as-is, experimental, and with limited-support.

*we@omne.earth*
