#!/usr/bin/env bash
# Copyright (C) 2026 Daryan Kamaran Karim
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The part of build-mesa.sh that runs inside the Debian trixie build root (or on a trixie host):
# builds one GPU family's Mesa into $WORK/stage-<family>. Not meant to be run by hand.
#   build-in-root.sh <work dir> <adreno|mali>
# Env (from build-mesa.sh): MESA_VERSION, PANVK_REPO, PANVK_REV, PREFIX, ON_HOST.
set -euo pipefail
WORK=$1
FAMILY=$2

if [ -z "${ON_HOST:-}" ]; then
  export DEBIAN_FRONTEND=noninteractive
  dpkg --add-architecture arm64
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends \
    ca-certificates binutils crossbuild-essential-arm64 meson ninja-build pkgconf pkgconf:arm64 bison flex xz-utils curl \
    python3-mako python3-yaml python3-packaging python3-ply glslang-tools patch \
    libdrm-dev:arm64 libexpat1-dev:arm64 zlib1g-dev:arm64 libzstd-dev:arm64 \
    libx11-dev:arm64 libxext-dev:arm64 libxfixes-dev:arm64 libxrandr-dev:arm64 libxxf86vm-dev:arm64 \
    libxshmfence-dev:arm64 libx11-xcb-dev:arm64 libxcb1-dev:arm64 libxcb-glx0-dev:arm64 libxcb-shm0-dev:arm64 \
    libxcb-dri3-dev:arm64 libxcb-present-dev:arm64 libxcb-randr0-dev:arm64 libxcb-sync-dev:arm64 \
    libxcb-xfixes0-dev:arm64 libxcb-keysyms1-dev:arm64 libglvnd-dev:arm64 >/dev/null
  if [ "$FAMILY" = mali ]; then
    # PanVK's internal shaders are OpenCL C, compiled at build time by Mesa's own CL compiler
    # (mesa_clc) and panfrost_compile, which run on the build machine: LLVM, libclc and the
    # SPIR-V translator for that machine, never for the phone.
    apt-get install -y -qq --no-install-recommends \
      clang llvm-dev libclang-dev libclang-cpp-dev libclc-19-dev libllvmspirvlib-19-dev \
      spirv-tools libdrm-dev libexpat1-dev zlib1g-dev >/dev/null
  fi
fi

mkdir -p "$WORK/src" && cd "$WORK/src"
# Mesa's source: a release for Adreno, the pinned PanVK fork (kbase backend) for Mali. Unpacked
# aside and moved into place whole, so an interrupted download is never taken for the source.
if [ "$FAMILY" = adreno ]; then
  SRC=mesa-$MESA_VERSION
  URL=https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz UNPACK=xJ
else
  SRC=panvk-$PANVK_REV
  URL=https://github.com/$PANVK_REPO/archive/$PANVK_REV.tar.gz UNPACK=xz
fi
if [ ! -d "$SRC" ]; then
  rm -rf "$SRC.part" && mkdir "$SRC.part"
  curl -fsSL "$URL" | tar "$UNPACK" --strip-components=1 -C "$SRC.part"
  mv "$SRC.part" "$SRC"
fi
cd "$SRC"

# Our fixes. For Mali, one in patches-panvk replaces the one of the same name in patches (its
# rebase onto the fork), and patches-panvk's others are added. One a reused source tree already
# has is skipped; one that doesn't apply stops the build, rather than shipping a driver without it.
patches=()
for p in "$WORK"/patches/*.patch; do
  if [ "$FAMILY" = mali ] && [ -f "$WORK/patches-panvk/$(basename "$p")" ]; then continue; fi
  patches+=("$p")
done
[ "$FAMILY" = mali ] && patches+=("$WORK"/patches-panvk/*.patch)
for p in "${patches[@]}"; do
  [ -f "$p" ] || continue
  if patch -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1; then
    echo "already applied: $(basename "$p")"
  else
    patch -p1 -N < "$p"
  fi
done

cat > "$WORK/src/arm64.cross" <<CROSS
[binaries]
c = 'aarch64-linux-gnu-gcc'
cpp = 'aarch64-linux-gnu-g++'
ar = 'aarch64-linux-gnu-ar'
strip = 'aarch64-linux-gnu-strip'
pkg-config = 'aarch64-linux-gnu-pkg-config'
[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
CROSS

COMMON=(
  --cross-file "$WORK/src/arm64.cross"
  --prefix="$PREFIX" --libdir=lib --buildtype=release -Db_ndebug=true
  -Dplatforms=x11 -Dgallium-drivers=zink
  -Dglx=dri -Degl=enabled -Dgles1=disabled -Dgles2=enabled -Dglvnd=enabled
  -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dvideo-codecs= -Dtools= -Dvulkan-layers=
)
if [ "$FAMILY" = adreno ]; then
  FLAGS=(-Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl)
else
  # The build machine's CL compilers first (built once per source tree), then the phone's
  # driver with them: kbase only, as Android has no panfrost/panthor DRM device.
  # Keyed on the fork's revision and our patches to it, which the compilers are built with too.
  TOOLS="$WORK/host-tools-$PANVK_REV-$(cat "$WORK"/patches-panvk/*.patch 2>/dev/null | sha256sum | cut -c1-12)"
  if [ ! -d "$TOOLS" ]; then
    rm -rf build-host
    # With clang: the fork's SPIR-V linker check passes clang-only warning flags, which make GCC
    # fail it and blame an old SPIRV-Tools.
    CC=clang CXX=clang++ meson setup build-host --buildtype=release -Dllvm=enabled \
      -Dmesa-clc=enabled -Dprecomp-compiler=enabled \
      -Dplatforms= -Dvulkan-drivers=panfrost -Dpanfrost-kmds=panthor -Dgallium-drivers= \
      -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
      -Dxmlconfig=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dvideo-codecs= -Dtools= \
      -Dvulkan-layers= -Dbuild-tests=false
    meson compile -C build-host mesa_clc vtn_bindgen2 panfrost_compile
    rm -rf "$TOOLS.part" && mkdir "$TOOLS.part"
    for t in mesa_clc vtn_bindgen2 panfrost_compile; do
      tool=$(find build-host -name "$t" -type f -executable | head -1)
      [ -n "$tool" ] || { echo "host tool $t wasn't built" >&2; exit 1; }
      cp "$tool" "$TOOLS.part/"
    done
    mv "$TOOLS.part" "$TOOLS"
  fi
  export PATH="$TOOLS:$PATH"
  FLAGS=(-Dvulkan-drivers=panfrost -Dpanfrost-kmds=kbase -Dmesa-clc=system -Dprecomp-compiler=system)
fi

rm -rf build
meson setup build "${COMMON[@]}" "${FLAGS[@]}"
ninja -C build
rm -rf "$WORK/stage-$FAMILY" && DESTDIR="$WORK/stage-$FAMILY" ninja -C build install
aarch64-linux-gnu-strip --strip-unneeded $(find "$WORK/stage-$FAMILY" -name '*.so*' -type f)
