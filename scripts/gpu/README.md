# GPU drivers

`build-mesa.sh` builds one Mesa per GPU family into `build/gpu/assets/gpu`, which the APK
carries; the app unpacks the one matching the phone's GPU into a container's `/opt/tessera-gpu`.

| Family | Driver | Source | Archive | Version file |
|---|---|---|---|---|
| Adreno (Snapdragon) | Turnip, KGSL | Mesa release `MESA_VERSION` | `mesa-turnip.tgz` | `VERSION` |
| Mali (MediaTek, Exynos, Tensor) | PanVK, kbase | [leo-snczki/mali-panvk](https://github.com/leo-snczki/mali-panvk) (mirror of JimVulkan/mali-panvk) at `PANVK_REV`, for Vulkan | `mesa-panvk.tgz` | `VERSION-panvk` |

Both come with Zink, GLX and EGL (OpenGL on Vulkan) from the Mesa release: Zink reaches the
Vulkan driver through the loader, so PanVK needn't come from the same tree (and the port carries
no OpenGL). `patches/` applies to the Mesa release; the PanVK tree gets its WSI patches, where a
patch in `patches-panvk/` replaces the one of the same name (its rebase onto the port). A patch
that doesn't apply stops the build.

```sh
sudo scripts/gpu/build-mesa.sh                       # both, in a debootstrapped trixie root
MESA_GPU=mali sudo -E scripts/gpu/build-mesa.sh      # only one family
docker run --rm -v "$PWD:/src" -w /src debian:trixie env TRIXIE=/ scripts/gpu/build-mesa.sh   # no root
```

## Mali: where PanVK comes from

Upstream Mesa can't use Android's Mali kernel driver (`/dev/mali0`, "kbase"). The kbase backend
lives in community ports. We use [JimVulkan/mali-panvk](https://github.com/JimVulkan/mali-panvk)
(MIT, Mesa 27.0-devel): it has every Mali arch from Bifrost to the G1, v11 (G615/G715)
included, which yo-www/panvk, tried first, lacks ("Unknown gpu_id (0xb8a31030)" on a G615).
It is cut down to what Android needs, so the build fills in Mesa's X11 and loader helpers and
the headers they include from the release beside it. We build from our own mirror,
`leo-snczki/mali-panvk`, pinned to one full commit, so a rewritten or deleted upstream never
changes or breaks a build.

## Updating PanVK

Claude does this when asked ("update PanVK"); it needs the Mali test tablet plugged in over USB
(adb from `nix shell nixpkgs#android-tools`).

1. Sync the mirror: fetch `https://github.com/JimVulkan/mali-panvk.git` `main` into a clone of
   `leo-snczki/mali-panvk` and push `main`. If upstream rewrote history, push the new history to
   a branch named after the date instead of force-pushing, so old pins keep resolving.
2. Pick the new commit (normally upstream's head) and read what changed since `PANVK_REV`,
   especially anything about kbase, WSI or the arch table.
3. Set `PANVK_REV` in `build-mesa.sh` and bump the `-pN` suffix written to `VERSION-panvk` only
   if the patches changed (the revision is already in the version).
4. Build: `MESA_GPU=mali`, in docker as above. Fix or rebase any patch that no longer applies
   (Mali-only rebases go in `patches-panvk/`).
5. Install the side-by-side build on the tablet (`./gradlew assembleDebug -Ptessera.idSuffix=.debug`,
   `adb install -r`) and check in a PRoot GPU session: `vulkaninfo --summary` (driver `panvk`),
   `glxinfo -B` (Zink on the Mali GPU), `glxgears`, Firefox.
6. Commit as `build(gpu): bump PanVK to <short rev>` with what was tested in the body.
