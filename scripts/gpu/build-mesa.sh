#!/usr/bin/env bash
# Copyright (C) 2026 Daryan Kamaran Karim
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds the GPU drivers the containers use, for Debian trixie arm64, one per GPU family:
#   adreno: Mesa's Turnip (Vulkan) for Android's KGSL GPU interface;
#   mali:   Mesa's PanVK (Vulkan) for Android's Mali kbase interface, from the port that adds it
#           ($PANVK_REPO, pinned to $PANVK_REV; see scripts/gpu/README.md), or with
#           PANVK_SOURCE=zenith from zenithblue's patch series for the Mali-G615 ($ZENITH_REPO,
#           pinned to $ZENITH_REV) on the Mesa commit that series pins;
# each with Zink (OpenGL on Vulkan) from the Mesa release. Debian's own Mesa only knows the
# desktop DRM interfaces, which Android doesn't give apps.
#
# Cross-compiles inside a Debian trixie root (so the libraries match the containers exactly)
# and packs each as build/gpu/assets/gpu/mesa-<driver>.tgz with its version file (bundled into
# the APK by app/build.gradle.kts; builds without them just have no GPU acceleration), which the
# app unpacks into a container's /opt/tessera-gpu, the one matching the phone's GPU.
#
# Needs a Linux host (WSL is fine) and root, for the build root:
#   sudo scripts/gpu/build-mesa.sh
# Or, on a Debian trixie host that has the packages installed (see build-in-root.sh; F-Droid's
# build server does, from its recipe), without a build root or root:
#   TESSERA_ON_HOST=1 scripts/gpu/build-mesa.sh
# Or in a trixie container, without root on the host (rootless docker is enough):
#   docker run --rm -v "$PWD:/src" -w /src debian:trixie env TRIXIE=/ scripts/gpu/build-mesa.sh
# Env: MESA_GPU (adreno, mali or all, the default), MESA_VERSION, PANVK_SOURCE (port, the default,
# or zenith), PANVK_REV, ZENITH_REV, ZENITH_CSF_MAX and ZENITH_WIP_MAX (defaults below), TRIXIE
# (the build root, default /opt/trixie).
set -euo pipefail

export MESA_VERSION=${MESA_VERSION:-26.2.4}
export PANVK_REPO=${PANVK_REPO:-leo-snczki/mali-panvk}
export PANVK_REV=${PANVK_REV:-58f2c55854bd48b18df756edb11f187af9cd2fde}
export PANVK_SOURCE=${PANVK_SOURCE:-port}
export ZENITH_REPO=${ZENITH_REPO:-zenithblue-oss/panvk-kbase-android}
export ZENITH_REV=${ZENITH_REV:-cf70e02b918e1864cbcd746a7fefa57b96c673ce}
# How much of their series goes in, as their own release builds take it (prepare-rc5-tree.sh at
# that commit): the csf-v11 patches up to this number, then their jm-v7-wip patches 0006 up to this.
export ZENITH_CSF_MAX=${ZENITH_CSF_MAX:-233}
export ZENITH_WIP_MAX=${ZENITH_WIP_MAX:-0175}
export PREFIX=/opt/tessera-gpu
MESA_GPU=${MESA_GPU:-all}
TRIXIE=${TRIXIE:-/opt/trixie}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/../../build/gpu/assets/gpu"
export ON_HOST=${TESSERA_ON_HOST:-}
# A full commit id: it names the version phones compare, so it must never mean two trees.
[[ $PANVK_REV =~ ^[0-9a-f]{40}$ ]] || { echo "PANVK_REV must be a full commit id" >&2; exit 1; }
[[ $ZENITH_REV =~ ^[0-9a-f]{40}$ ]] || { echo "ZENITH_REV must be a full commit id" >&2; exit 1; }
[[ $ZENITH_CSF_MAX =~ ^[0-9]+$ && $ZENITH_WIP_MAX =~ ^[0-9]{4}$ ]] || { echo "ZENITH_CSF_MAX is a number, ZENITH_WIP_MAX four digits" >&2; exit 1; }
case $PANVK_SOURCE in port|zenith) ;; *) echo "PANVK_SOURCE must be port or zenith" >&2; exit 1 ;; esac
case $MESA_GPU in
  all) FAMILIES="adreno mali" ;;
  adreno|mali) FAMILIES=$MESA_GPU ;;
  *) echo "MESA_GPU must be adreno, mali or all" >&2; exit 1 ;;
esac
# Where the build works: in the build root, or a folder of our own on the host.
if [ -n "$ON_HOST" ]; then
  mkdir -p "$HERE/../../build/gpu-work"
  WORK=$(cd "$HERE/../../build/gpu-work" && pwd)
  INNER=$WORK
else
  WORK="$TRIXIE/work"
  INNER=/work
fi

if [ -z "$ON_HOST" ] && [ ! -x "$TRIXIE/usr/bin/apt-get" ]; then
  apt-get install -y debootstrap
  debootstrap --variant=buildd --include=ca-certificates trixie "$TRIXIE" http://deb.debian.org/debian
fi

mkdir -p "$WORK"
rm -rf "$WORK/patches" "$WORK/patches-panvk"
cp -r "$HERE/patches" "$WORK/patches"
[ -d "$HERE/patches-panvk" ] && cp -r "$HERE/patches-panvk" "$WORK/patches-panvk"
cp "$HERE/build-in-root.sh" "$WORK/build-in-root.sh"
# TRIXIE=/ builds in the system itself: a trixie container (docker run debian:trixie).
if [ -z "$ON_HOST" ] && ! [ "$TRIXIE" -ef / ]; then
  cp /etc/resolv.conf "$TRIXIE/etc/resolv.conf"
  mountpoint -q "$TRIXIE/proc" || mount -t proc proc "$TRIXIE/proc"
  trap 'umount "$TRIXIE/proc" 2>/dev/null || true' EXIT
fi

mkdir -p "$OUT"
for family in $FAMILIES; do
  if [ -n "$ON_HOST" ]; then
    bash "$WORK/build-in-root.sh" "$INNER" "$family"
  else
    chroot "$TRIXIE" /bin/bash /work/build-in-root.sh "$INNER" "$family"
  fi
  stage="$WORK/stage-$family"
  # Headers and pkg-config files are for building against it; apps only need the libraries.
  rm -rf "$stage$PREFIX/include" "$stage$PREFIX/lib/pkgconfig"
  # Bump the suffixes when the patches change, so phones unpack the new build. The family is in
  # the version, so a container that has the other family's driver never passes for this one's.
  if [ "$family" = adreno ]; then
    tar --format=ustar -C "$stage" -czf "$OUT/mesa-turnip.tgz" "${PREFIX#/}"
    echo "$MESA_VERSION-t5" > "$OUT/VERSION"
  else
    tar --format=ustar -C "$stage" -czf "$OUT/mesa-panvk.tgz" "${PREFIX#/}"
    # Both trees: PanVK's revision and the release its OpenGL comes from (and, for the port, its
    # helpers). The series' name marks the other source, so the two never pass for each other.
    if [ "$PANVK_SOURCE" = zenith ]; then
      echo "panvk-zenith-${ZENITH_REV:0:12}-w$ZENITH_WIP_MAX-mesa$MESA_VERSION-p1" > "$OUT/VERSION-panvk"
    else
      echo "panvk-${PANVK_REV:0:12}-mesa$MESA_VERSION-p6" > "$OUT/VERSION-panvk"
    fi
  fi
done
ls -l "$OUT"
