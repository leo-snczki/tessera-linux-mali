#!/usr/bin/env bash
# Copyright (C) 2026 Daryan Kamaran Karim
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The part of build-mesa.sh that runs inside the Debian trixie build root (or on a trixie host):
# builds one GPU family's driver into $WORK/stage-<family>: the Mesa release (OpenGL through
# Zink, and Turnip for Adreno), plus PanVK for Mali, from its kbase port or from zenithblue's patch
# series on a pinned Mesa. Not meant to be run by hand.
#   build-in-root.sh <work dir> <adreno|mali>
# Env (from build-mesa.sh): MESA_VERSION, PANVK_SOURCE, PANVK_REPO, PANVK_REV, ZENITH_REPO,
# ZENITH_REV, ZENITH_CSF_MAX, ZENITH_WIP_MAX, PREFIX, ON_HOST.
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
      spirv-tools libdrm-dev libexpat1-dev zlib1g-dev git >/dev/null
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

# Fetches only the patch series, profiles and Mesa pin of zenithblue's repo at $ZENITH_REV as
# $WORK/src/zenith-<rev>: the rest of that repo (its apps, DXVK and vkd3d) is gigabytes we don't use.
fetch_series() {
  local dir="$WORK/src/zenith-$ZENITH_REV"
  [ -d "$dir" ] && return
  rm -rf "$dir.part" && mkdir "$dir.part"
  git -C "$dir.part" init -q
  git -C "$dir.part" remote add origin "https://github.com/$ZENITH_REPO.git"
  git -C "$dir.part" sparse-checkout set patches profiles
  git -C "$dir.part" fetch -q --depth 1 --filter=blob:none origin "$ZENITH_REV"
  git -C "$dir.part" checkout -q FETCH_HEAD
  mv "$dir.part" "$dir"
}

# Applies zenithblue's series for a Mali-G615 to the Mesa tree in the current directory, as their
# prepare-rc5-tree.sh does for their release builds: the profile's list (the same as their
# apply-patches.sh), with the csf-v11 patches only up to $ZENITH_CSF_MAX, then their jm-v7-wip
# patches from 0006 up to $ZENITH_WIP_MAX, which later csf-v11 ones build on (patch 226 uses the
# gs_bo_pool that wip 0022 adds). git apply, as the patches are git's and some need their hunk
# counts recomputed; one that doesn't apply stops the build.
apply_series() { # <series dir>
  local fam p b opt
  # Its own git root, so a build folder inside another repo (TESSERA_ON_HOST) can't change what
  # git apply takes the patches' paths relative to.
  git init -q .
  for fam in common android kbase-common app-loader wsi csf csf-v11 jm-v9 jm-v7; do
    for p in "$1/patches/$fam"/*.patch; do
      [ -f "$p" ] || continue
      b=$(basename "$p")
      if [ "$fam" = csf-v11 ] && [ "${b%%-*}" -gt "$ZENITH_CSF_MAX" ]; then continue; fi
      git apply --check "$p" 2>/dev/null || opt=--recount
      git apply ${opt:-} "$p"
      opt=
    done
    if [ -d "$1/patches/$fam/files" ]; then
      (cd "$1/patches/$fam/files" && find . -type f ! -name README -print0 | tar --null -cf - -T -) | tar -xf -
    fi
  done
  for p in "$1"/patches/jm-v7-wip/0*.patch; do
    b=$(basename "$p")
    [ "${b%%-*}" -le "$ZENITH_WIP_MAX" ] || continue
    git apply "$p"
  done
  # The patch level their driverInfo reads (wip 0154), beside the tree, not in it.
  printf 'p%s\n' "$ZENITH_WIP_MAX" > .panvk-patchlevel
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
  # PanVK, Vulkan only (neither source carries OpenGL): from zenithblue's series on the Mesa it
  # pins, or from the kbase port. Either way TOOLS_KEY names what the host tools below were built
  # from, and VK_OPTS are the options only that source takes.
  VK_OPTS=()
  if [ "$PANVK_SOURCE" = zenith ]; then
    fetch_series
    SERIES="$WORK/src/zenith-$ZENITH_REV"
    # The Mesa commit the series was made against; it applies to nothing else.
    MESA_PIN=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['mesaCommit'])" "$SERIES/sources.lock")
    [[ $MESA_PIN =~ ^[0-9a-f]{40}$ ]] || { echo "no Mesa commit in the series' sources.lock" >&2; exit 1; }
    fetch "mesa-$MESA_PIN" "https://gitlab.freedesktop.org/mesa/mesa/-/archive/$MESA_PIN/mesa-$MESA_PIN.tar.gz" xz
    # The pristine tree stays as downloaded; the patched copy is made whole, then moved in place.
    TREE="panvk-zenith-$ZENITH_REV-c$ZENITH_CSF_MAX-w$ZENITH_WIP_MAX"
    if [ ! -d "$WORK/src/$TREE" ]; then
      rm -rf "$WORK/src/$TREE.part"
      cp -a "$WORK/src/mesa-$MESA_PIN" "$WORK/src/$TREE.part"
      (cd "$WORK/src/$TREE.part" && apply_series "$SERIES")
      mv "$WORK/src/$TREE.part" "$WORK/src/$TREE"
    fi
    cd "$WORK/src/$TREE"
    TOOLS_KEY=${TREE#panvk-}
    # kbase is the kernel interface, and no zstd keeps the driver's libraries to what a container has.
    VK_OPTS=(-Dpanfrost-kmds=kbase -Dzstd=disabled)
  else
    # PanVK from the kbase port, with our WSI fixes: those rebased onto it from patches-panvk, the
    # others from patches.
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
    # Keyed on its revision and our patches to it.
    TOOLS_KEY="$PANVK_REV-$(cat /dev/null "${wsi[@]}" | sha256sum | cut -c1-12)"
  fi
  # PanVK's OpenCL helpers are compiled at build time by Mesa's CL compilers from the same tree,
  # built first for the build machine.
  TOOLS="$WORK/host-tools-$TOOLS_KEY"
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
    -Dmesa-clc=system -Dprecomp-compiler=system "${VK_OPTS[@]}"
fi
aarch64-linux-gnu-strip --strip-unneeded $(find "$STAGE" -name '*.so*' -type f)
