#!/usr/bin/env bash
# ============================================================================
# RAUC for the DE25-Standard (docs/plan_rauc.md, step 1.1), both static:
#   ${BUILD_DIR}/rauc/rauc-aarch64   the board's: install, status, info
#                                    (no D-Bus service, network, streaming,
#                                    JSON, GPT or PKCS#11; no bundle creation)
#   ${BUILD_DIR}/rauc/rauc-host      this PC's (x86_64): bundle creation and
#                                    checks; needs mksquashfs/unsquashfs
#                                    (squashfs-tools) on the PATH
#
# Alpine has RAUC only in edge, at 1.10.1, which has no artifact
# repositories, so it is built here: 1.15.2, as the Zynq Mini project's
# Buildroot. This host cannot run arm64 containers (no binfmt), so the board's
# binary is cross-compiled with clang in an x86_64 Alpine container, against
# an aarch64 Alpine sysroot fetched with apk (signatures checked with
# Alpine's aarch64 keys). The host binary is a native build in the same
# container. Alpine has no static libeconf (libblkid needs it), so
# libeconf's sources are compiled in as well.
#
#   ./build.sh rauc       or   linux/build_rauc.sh
#
# REQUIREMENTS: docker (pulls alpine:3.24 for linux/amd64), internet.
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-${HERE}/../build}"
mkdir -p "${BUILD_DIR}"
BUILD_DIR="$(cd "${BUILD_DIR}" && pwd)"
DL="${BUILD_DIR}/downloads"
OUT="${BUILD_DIR}/rauc"

ALPINE_IMAGE="alpine:3.24"
ALPINE_BRANCH="v3.24"
RAUC_VERSION="1.15.2"
RAUC_URL="https://github.com/rauc/rauc/releases/download/v${RAUC_VERSION}/rauc-${RAUC_VERSION}.tar.xz"
RAUC_SHA256="127a24cde208c65b837ae978c695a00730f1094ee8b6c7d48cf58ef846eae340"
# the version Alpine's libblkid was built against (libeconf-0.8.3-r0)
ECONF_VERSION="0.8.3"
ECONF_URL="https://github.com/openSUSE/libeconf/archive/refs/tags/v${ECONF_VERSION}.tar.gz"
ECONF_SHA256="c8855f08d64c06b57a5028a14eec6ddde5e35124f9718031d592b44d8e091f83"

fetch() {   # fetch URL FILE SHA256
    [[ -f "$2" ]] || wget -q -O "$2" "$1"
    echo "$3  $2" | sha256sum -c --quiet - || { echo "ERROR: $2 checksum mismatch"; exit 1; }
}
mkdir -p "${DL}" "${OUT}"
fetch "${RAUC_URL}" "${DL}/rauc-${RAUC_VERSION}.tar.xz" "${RAUC_SHA256}"
fetch "${ECONF_URL}" "${DL}/libeconf-${ECONF_VERSION}.tar.gz" "${ECONF_SHA256}"
command -v docker >/dev/null || { echo "ERROR: docker is needed"; exit 1; }

# ---- the build, inside the container --------------------------------------
cat > "${OUT}/.inside.sh" << 'INSIDE'
set -eu
cd /tmp
SR=/sysroot
R="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}"
LIBS="glib-dev glib-static openssl-dev openssl-libs-static libffi-dev pcre2-dev
      pcre2-static zlib-dev zlib-static gettext-static util-linux-dev
      util-linux-static libeconf-dev"
echo ">> host packages"
apk add -q llvm clang lld meson ninja pkgconf file binutils gcc musl-dev $LIBS
echo ">> aarch64 sysroot"
mkdir -p $SR
apk add -q --root $SR --arch aarch64 --initdb --no-scripts \
    --keys-dir /usr/share/apk/keys/aarch64 -X "$R/main" -X "$R/community" -U \
    musl-dev gcc $LIBS

tar xJf "/dl/rauc-${RAUC_VERSION}.tar.xz"
tar xzf "/dl/libeconf-${ECONF_VERSION}.tar.gz"

# libeconf, static, for both: its read_file() would clash with RAUC's
econf() {   # econf CC AR LIBDIR
    rm -rf econf-obj && mkdir econf-obj
    for f in /tmp/libeconf-${ECONF_VERSION}/lib/*.c; do
        $1 -O2 -D_GNU_SOURCE -Dread_file=econf_read_file_ \
            -I/tmp/libeconf-${ECONF_VERSION}/include -I/tmp/libeconf-${ECONF_VERSION}/lib \
            -c "$f" -o "econf-obj/$(basename "$f" .c).o"
    done
    $2 rcs "$3/libeconf.a" econf-obj/*.o
}
econf "clang --target=aarch64-alpine-linux-musl --sysroot=$SR" llvm-ar $SR/usr/lib
econf gcc ar /usr/lib

cat > cross.txt << X
[binaries]
c = ['clang', '--target=aarch64-alpine-linux-musl', '--sysroot=$SR', '-fuse-ld=lld', '--gcc-toolchain=$SR/usr']
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'
[properties]
sys_root = '$SR'
pkg_config_libdir = '$SR/usr/lib/pkgconfig:$SR/usr/share/pkgconfig'
[built-in options]
c_link_args = ['-static', '-leconf']
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'cortex-a55'
endian = 'little'
X
printf "[built-in options]\nc_link_args = ['-static', '-leconf']\n" > native.txt

COMMON="--prefer-static --default-library=static --buildtype=release
        -Dservice=false -Dnetwork=false
        -Dstreaming=false -Djson=disabled -Dgpt=disabled -Dpkcs11_engine=false
        -Dtests=false"
echo ">> rauc ${RAUC_VERSION}, aarch64"
PKG_CONFIG_SYSROOT_DIR=$SR meson setup b-arm "rauc-${RAUC_VERSION}" --cross-file cross.txt \
    $COMMON -Dcreate=false > setup-arm.log 2>&1 || { tail -30 setup-arm.log; exit 1; }
PKG_CONFIG_SYSROOT_DIR=$SR ninja -C b-arm > ninja-arm.log 2>&1 || { grep -v -i warning ninja-arm.log | tail -30; exit 1; }
echo ">> rauc ${RAUC_VERSION}, x86_64 (bundle creation)"
meson setup b-host "rauc-${RAUC_VERSION}" --native-file native.txt $COMMON -Dcreate=true > setup-host.log 2>&1 || { tail -30 setup-host.log; exit 1; }
ninja -C b-host > ninja-host.log 2>&1 || { grep -v -i warning ninja-host.log | tail -30; exit 1; }

llvm-strip -o /out/rauc-aarch64 b-arm/rauc
strip -o /out/rauc-host b-host/rauc
# what went in, for the record
apk info -v --root $SR 2>/dev/null | sort > /out/sysroot-packages.txt
chown "${OWNER}" /out/rauc-aarch64 /out/rauc-host /out/sysroot-packages.txt
INSIDE

echo ">> building RAUC ${RAUC_VERSION} in ${ALPINE_IMAGE} (linux/amd64)"
docker run --rm --platform linux/amd64 \
    -e ALPINE_BRANCH="${ALPINE_BRANCH}" -e RAUC_VERSION="${RAUC_VERSION}" \
    -e ECONF_VERSION="${ECONF_VERSION}" -e OWNER="$(id -u):$(id -g)" \
    -v "${DL}:/dl:ro" -v "${OUT}:/out" \
    "${ALPINE_IMAGE}" sh /out/.inside.sh
rm -f "${OUT}/.inside.sh"

# ---- checks ---------------------------------------------------------------
file "${OUT}/rauc-aarch64" | grep -q 'ARM aarch64.*statically linked' || {
    echo "ERROR: rauc-aarch64 is not a static aarch64 binary"; exit 1; }
file "${OUT}/rauc-host" | grep -q 'x86-64.*static' || {
    echo "ERROR: rauc-host is not a static x86_64 binary"; exit 1; }
"${OUT}/rauc-host" --version | grep -q "rauc ${RAUC_VERSION}" || {
    echo "ERROR: rauc-host does not run"; exit 1; }
if command -v qemu-aarch64-static >/dev/null; then
    qemu-aarch64-static "${OUT}/rauc-aarch64" --version | grep -q "rauc ${RAUC_VERSION}" || {
        echo "ERROR: rauc-aarch64 does not run under qemu"; exit 1; }
fi
command -v mksquashfs >/dev/null || echo "NOTE: no mksquashfs here - rauc-host needs squashfs-tools to make bundles"
echo ">> done:"
ls -l "${OUT}/rauc-aarch64" "${OUT}/rauc-host"
