# The image every Woodpecker step runs in (ops/ci/README.md). Ubuntu 24.04, as GitHub's runners
# were; Zig from ziglang.org, verified against the SHA-256 that .github/actions/setup-zig pins;
# QEMU from apt for the VM demos. `bootstrap.sh` builds it on the box as zigbox-ci:<ZIG_VERSION>.
#
# `tester` (uid 1001) is the ordinary user: `zig build check` run as root re-runs the tests as it,
# and the VM demos run as it. KVM_GID is the box's `kvm` group id, so `tester` may open /dev/kvm
# in a privileged step without anyone changing the device's mode on the host. The base is pinned
# by digest; the apt packages follow the archive, as on GitHub's runners.
FROM ubuntu:24.04@sha256:9c7f200c07e3d4a03e7249d2c16bf66a51120fb876aa2242cf31451412543289

ARG ZIG_VERSION=0.17.0
ARG ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ARG KVM_GID=992

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git xz-utils jq util-linux \
        qemu-system-x86 qemu-utils dbus; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    archive="zig-x86_64-linux-${ZIG_VERSION}.tar.xz"; \
    curl -fsSL --retry 3 -o "/tmp/${archive}" "https://ziglang.org/download/${ZIG_VERSION}/${archive}"; \
    echo "${ZIG_SHA256}  /tmp/${archive}" | sha256sum -c -; \
    tar -xJf "/tmp/${archive}" -C /opt; \
    rm "/tmp/${archive}"; \
    ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig; \
    zig version

RUN set -eux; \
    if getent group "${KVM_GID}" >/dev/null; then \
        groupmod -n kvm-host "$(getent group "${KVM_GID}" | cut -d: -f1)" || true; \
    else \
        groupadd -g "${KVM_GID}" kvm-host; \
    fi; \
    useradd -m -u 1001 -G "${KVM_GID}" tester; \
    git config --system --add safe.directory '*'

ENV ZIG_VERSION=${ZIG_VERSION}
