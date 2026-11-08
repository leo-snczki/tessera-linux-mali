#!/usr/bin/env bash
# Copyright (C) 2026 Daryan Kamaran Karim
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The part of build-mesa.sh that runs inside the Debian trixie build root (or on a trixie host):
# builds one GPU family's driver into $WORK/stage-<family>: the Mesa release (OpenGL through
# Zink, and Turnip for Adreno), plus PanVK from its kbase port for Mali. Not meant to be run by hand.
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

mkdir -p "$WORK/src"

# Unpacks <url> as $WORK/src/<dir>, aside first and moved into place whole, so an interrupted
# download is never taken for the source.
fetch() { # <dir> <url> <tar option>
  [ -d "$WORK/src/$1" ] && return
  rm -rf "$WORK/src/$1.part" && mkdir "$WORK/src/$1.part"
  curl -fsSL "$2" | tar "$3" --strip-components=1 -C "$WORK/src/$1.part"
  mv "$WORK/src/$1.part" "$WORK/src/$1"
}

# Applies our fixes to the source tree in the current directory. One a reused tree already has
# is skipped; one that doesn't apply stops the build, rather than shipping a driver without it.
apply_patches() { # <patch>...
  for p in "$@"; do
    [ -f "$p" ] || continue
    if patch -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1; then
      echo "already applied: $(basename "$p")"
    else
      patch -p1 -N < "$p"
    fi
  done
}

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

# Cross-builds the tree in the current directory into build-<name> and installs it into $STAGE.
cross_build() { # <name> <meson option>...
  local name=$1; shift
  rm -rf "build-$name"
  meson setup "build-$name" --cross-file "$WORK/src/arm64.cross" \
    --prefix="$PREFIX" --libdir=lib --buildtype=release -Db_ndebug=true -Dplatforms=x11 \
    -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dvideo-codecs= -Dtools= -Dvulkan-layers= \
    "$@"
  ninja -C "build-$name"
  DESTDIR="$STAGE" ninja -C "build-$name" install
}
# OpenGL through Zink (on whatever Vulkan driver the loader finds), with GLX and EGL.
GL=(-Dgallium-drivers=zink -Dglx=dri -Degl=enabled -Dgles1=disabled -Dgles2=enabled -Dglvnd=enabled)

STAGE="$WORK/stage-$FAMILY"
rm -rf "$STAGE"
fetch "mesa-$MESA_VERSION" "https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz" xJ
cd "$WORK/src/mesa-$MESA_VERSION"
apply_patches "$WORK"/patches/*.patch

if [ "$FAMILY" = adreno ]; then
  cross_build adreno "${GL[@]}" -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl
else
  # OpenGL from the Mesa release, as for Adreno; Zink reaches PanVK through the Vulkan loader,
  # so the two needn't come from the same tree.
  cross_build gl "${GL[@]}" -Dvulkan-drivers=
  # PanVK from the kbase port, Vulkan only (it carries no OpenGL), with our WSI fixes: those
  # rebased onto it from patches-panvk, the others from patches.
  # One tree per Mesa release too, as the helpers below come from it.
  fetch "panvk-$PANVK_REV-$MESA_VERSION" "https://github.com/$PANVK_REPO/archive/$PANVK_REV.tar.gz" xz
  cd "$WORK/src/panvk-$PANVK_REV-$MESA_VERSION"
  wsi=()
  for p in "$WORK"/patches/wsi-*.patch; do
    [ -f "$p" ] || continue
    if [ -f "$WORK/patches-panvk/$(basename "$p")" ]; then wsi+=("$WORK/patches-panvk/$(basename "$p")"); else wsi+=("$p"); fi
  done
  for p in "$WORK"/patches-panvk/*.patch; do
    [ -f "$p" ] && [ ! -f "$WORK/patches/$(basename "$p")" ] && wsi+=("$p")
  done
  apply_patches "${wsi[@]}"
  # The port is cut down to what Android needs; X11 presenting also needs Mesa's X11 and loader
  # helpers, small and stable, taken from the release beside it.
  for d in src/x11 src/loader; do
    [ -d "$d" ] || cp -r "$WORK/src/mesa-$MESA_VERSION/$d" "$d"
  done
  # And the headers they include, where the port dropped them (never replacing its own).
  cp -rn "$WORK/src/mesa-$MESA_VERSION/include/." include/
  # Its OpenCL helpers are compiled at build time by Mesa's CL compilers from the same tree,
  # built first for the build machine. Keyed on its revision and our patches to it.
  TOOLS="$WORK/host-tools-$PANVK_REV-$(cat /dev/null "${wsi[@]}" | sha256sum | cut -c1-12)"
  if [ ! -d "$TOOLS" ]; then
    rm -rf build-host
    # With clang: Mesa's SPIR-V linker check passes clang-only warning flags, which make GCC
    # fail it and blame an old SPIRV-Tools.
    CC=clang CXX=clang++ meson setup build-host --buildtype=release -Dllvm=enabled \
      -Dmesa-clc=enabled -Dprecomp-compiler=enabled \
      -Dplatforms= -Dvulkan-drivers=panfrost -Dgallium-drivers= \
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
  cross_build vk -Dvulkan-drivers=panfrost -Dgallium-drivers= -Dopengl=false -Dglx=disabled \
    -Degl=disabled -Dgbm=disabled -Dgles1=disabled -Dgles2=disabled \
    -Dmesa-clc=system -Dprecomp-compiler=system
fi
aarch64-linux-gnu-strip --strip-unneeded $(find "$STAGE" -name '*.so*' -type f)
