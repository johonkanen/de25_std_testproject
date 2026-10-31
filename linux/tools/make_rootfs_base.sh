#!/usr/bin/env bash
# make_rootfs_base.sh - the Alpine aarch64 minirootfs plus the packages the
# board needs, as one tarball (docs/plan_rauc.md step 2): every rootfs slot
# gets the same image, so nothing may be installed at first boot any more.
#
#   linux/tools/make_rootfs_base.sh     -> ${BUILD_DIR}/downloads/rootfs-base-<alpine>-<hash>.tar.gz
#                                          (prints the path; kept and reused)
#
# This host cannot run arm64 programs, so apk runs in an x86_64 Alpine
# container and installs the aarch64 packages into the extracted tree
# (--root --arch aarch64, signatures checked with the tree's own keys).
# --no-scripts: the packages here have no install scripts the board needs.
#
# Env: BUILD_DIR, ALPINE_VERSION (3.24.1), ROOTFS_PACKAGES.
set -euo pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${TOP}/build}"
ALPINE_VERSION="${ALPINE_VERSION:-3.24.1}"
# python3: the web GUI and the RAUC handler; e2fsprogs(-extra): resize2fs for
# RAUC's resize=true on the rootfs slots, e2fsck; dropbear: ssh (key login
# only, alpine_rootfs_config.sh), openssh-sftp-server: scp/sftp over it
ROOTFS_PACKAGES="${ROOTFS_PACKAGES:-python3 e2fsprogs e2fsprogs-extra dropbear openssh-sftp-server}"
DL="${BUILD_DIR}/downloads"
MINI="${DL}/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"
MINI_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/alpine-minirootfs-${ALPINE_VERSION}-aarch64.tar.gz"

mkdir -p "${DL}"
[[ -f "${MINI}" ]] || { echo ">> fetching Alpine ${ALPINE_VERSION} minirootfs" >&2; wget -q -O "${MINI}" "${MINI_URL}"; }
key="$( (sha256sum "${MINI}" | cut -d' ' -f1; echo "${ROOTFS_PACKAGES}"; sha256sum "$0" | cut -d' ' -f1) | sha256sum | cut -c1-12)"
OUT="${DL}/rootfs-base-${ALPINE_VERSION}-${key}.tar.gz"
if [[ -s "${OUT}" ]]; then
    echo "${OUT}"
    exit 0
fi
command -v docker >/dev/null || { echo "ERROR: docker is needed" >&2; exit 1; }
echo ">> rootfs base: Alpine ${ALPINE_VERSION} + ${ROOTFS_PACKAGES} (docker, apk --arch aarch64)" >&2
docker run --rm --platform linux/amd64 -e PKGS="${ROOTFS_PACKAGES}" -e OWNER="$(id -u):$(id -g)" \
    -e OUTNAME="$(basename "${OUT}")" -e MININAME="$(basename "${MINI}")" \
    -v "${DL}:/dl" alpine:3.24 sh -euc '
        mkdir /r
        tar xzf "/dl/${MININAME}" -C /r
        apk add -q --root /r --arch aarch64 --no-scripts --keys-dir /r/etc/apk/keys \
            --repositories-file /r/etc/apk/repositories -U ${PKGS} >&2
        rm -rf /r/var/cache/apk/*
        apk info --root /r 2>/dev/null | sort | tr "\n" " " >&2; echo >&2
        tar -C /r --numeric-owner -czf "/dl/${OUTNAME}.tmp" .
        chown "${OWNER}" "/dl/${OUTNAME}.tmp"
        mv "/dl/${OUTNAME}.tmp" "/dl/${OUTNAME}"
    '
[[ -s "${OUT}" ]] || { echo "ERROR: no ${OUT}" >&2; exit 1; }
echo "${OUT}"
