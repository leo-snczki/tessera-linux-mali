// Copyright (C) 2026 Daryan Kamaran Karim
// SPDX-License-Identifier: GPL-3.0-or-later

package com.daryan.tessera.container

import android.content.Context
import java.io.File

/**
 * Hardware graphics for GUI apps: our own Mesa build (scripts/gpu/build-mesa.sh) with a Vulkan
 * driver for the phone's GPU ([GpuFamily]), talking to Android's GPU device, and Zink giving
 * OpenGL on top of it. It lives apart from the distro's Mesa, in [GUEST_DIR], and apps are
 * pointed at it through their environment ([env]), so turning it off is just not doing that.
 */
object GpuDriver {
    const val GUEST_DIR = "/opt/tessera-gpu"
    internal const val TAG = "GpuDriver"

    /**
     * What makes apps use it, whatever the GPU. Frames reach the X server as plain images:
     * Termux:X11's DRI3 hangs Mesa (see LIBGL_DRI3_DISABLE), so GLX goes through Zink's Kopper
     * "DRI2" path and Vulkan presents in software ("sw"), without SysV shared memory, which
     * Android doesn't have ("noshm": with it, presenting dies of SIGBUS). Checked on an Adreno
     * 740: glxgears at ~240 fps, Firefox and HandBrake (GTK 4, EGL) drawing. The Vulkan driver
     * and its own options come from the [GpuFamily]; see [env].
     */
    private val ENV = mapOf(
        "LD_LIBRARY_PATH" to "$GUEST_DIR/lib",
        "__GLX_VENDOR_LIBRARY_NAME" to "mesa",
        "__EGL_VENDOR_LIBRARY_FILENAMES" to "$GUEST_DIR/share/glvnd/egl_vendor.d/50_mesa.json",
        "LIBGL_DRIVERS_PATH" to "$GUEST_DIR/lib/dri",
        "MESA_LOADER_DRIVER_OVERRIDE" to "zink",
        "GALLIUM_DRIVER" to "zink",
        "MESA_VK_WSI_DEBUG" to "sw,noshm",
        "LIBGL_KOPPER_DRI2" to "1",
    )

    /** What makes an app use [family]'s driver, with those of [fixes] that are its own. */
    fun env(family: GpuFamily, fixes: Set<GpuFix>): Map<String, String> =
        ENV + ("VK_ICD_FILENAMES" to "$GUEST_DIR/share/vulkan/icd.d/${family.icd}") +
            family.env(fixes.filterTo(linkedSetOf()) { it.family == family })

    /** Whether GPU acceleration starts on for [family]: not for an experimental one. */
    fun onByDefault(family: GpuFamily?): Boolean = family?.experimental != true

    // What family() found, once: neither the device nor the APK's assets change while the app runs.
    @Volatile private var detected = false
    @Volatile private var detectedFamily: GpuFamily? = null

    /** This phone's GPU, when this build carries its driver and the app can open the GPU. */
    fun family(context: Context): GpuFamily? {
        if (!detected) {
            detectedFamily = GpuFamily.entries.firstOrNull { File(it.device).canRead() && it.bundle.available(context) }
            detected = true
        }
        return detectedFamily
    }

    /**
     * Android's kernel driver for a Mali GPU, as its module is named (mali_kbase_mt6897_r44:
     * kbase release r44), for diagnostics; null where apps may not list kernel modules.
     */
    fun kernelDriver(): String? =
        runCatching { File("/sys/module").list()?.filter { it.startsWith("mali_kbase") }?.sorted()?.firstOrNull() }.getOrNull()

    /** Whether this build carries a driver for this phone's GPU, and the app can open it. */
    fun available(context: Context): Boolean = family(context) != null

    /** Whether this build's driver is unpacked in [rootfs], ready to use. */
    fun installed(context: Context, rootfs: File): Boolean =
        family(context)?.bundle?.installed(context, rootfs) == true

    /** Unpacks the driver into [rootfs]; see [OptBundle.install]. */
    fun install(context: Context, rootfs: File): Boolean =
        family(context)?.bundle?.install(context, rootfs) == true

    /** Whether this build's driver is in the chroot system; known once [installAsRoot] ran. */
    fun installedAsRoot(context: Context): Boolean =
        family(context)?.bundle?.installedAsRoot(context) == true

    /** Unpacks the driver into the chroot system; see [OptBundle.installAsRoot]. */
    fun installAsRoot(context: Context, rootfs: File, su: String): Boolean =
        family(context)?.bundle?.installAsRoot(context, rootfs, su) == true
}

/**
 * The kinds of GPU the driver knows, each with its own Mesa Vulkan driver, archive (unpacked
 * into [GpuDriver.GUEST_DIR]) and device node.
 */
enum class GpuFamily(
    /** The GPU's device node; world-readable and writable, so apps need no group for it. */
    val device: String,
    /** Its Vulkan driver's ICD file, in the driver's share/vulkan/icd.d. */
    val icd: String,
    internal val bundle: OptBundle,
    /** Off until the user turns it on, after a warning that it can restart some phones. */
    val experimental: Boolean = false,
) {
    /** Adreno (Snapdragon): Turnip, on Android's KGSL interface. */
    ADRENO(
        "/dev/kgsl-3d0",
        "freedreno_icd.aarch64.json",
        OptBundle(GpuDriver.GUEST_DIR, "gpu/mesa-turnip.tgz", "gpu/VERSION", GpuDriver.TAG),
    ) {
        override fun env(fixes: Set<GpuFix>) =
            mapOf("TU_DEBUG" to (listOf("noconform") + fixes.map { it.option }).joinToString(","))
    },

    /**
     * Mali (MediaTek, Exynos, Tensor): PanVK on Android's kbase interface, from a community
     * fork (see scripts/gpu/README.md). Experimental: kbase driven from a container can hit
     * kernel bugs that restart some phones.
     */
    MALI(
        "/dev/mali0",
        "panfrost_icd.aarch64.json",
        OptBundle(GpuDriver.GUEST_DIR, "gpu/mesa-panvk.tgz", "gpu/VERSION-panvk", GpuDriver.TAG),
        experimental = true,
    ) {
        override fun env(fixes: Set<GpuFix>) = emptyMap<String, String>()
    };

    /** The driver's own settings, with [fixes] (this family's) for its drawing bugs. */
    internal abstract fun env(fixes: Set<GpuFix>): Map<String, String>
}

/**
 * Workarounds for drawing bugs in a [family]'s driver, chosen per app from its Graphics fixes
 * menu. Each is one of the driver's options; [default] ones are on until the user turns them off.
 */
enum class GpuFix(val family: GpuFamily, val option: String, val default: Boolean) {
    /**
     * UBWC, Adreno's framebuffer compression, off. With it, some frames of Chromium-based apps
     * (VS Code) reach the window with only every sixth 16x16 block drawn, the rest black, until
     * the next frame. Costs memory bandwidth.
     */
    NO_COMPRESSION(GpuFamily.ADRENO, "noubwc", true),

    /** Draws straight to memory instead of in tiles (GMEM), for parts drawn wrong or missing. */
    DIRECT_RENDERING(GpuFamily.ADRENO, "sysmem", false),

    /** Flushes caches and waits after every draw, for flicker and half-drawn frames. Slow. */
    SYNC_DRAWS(GpuFamily.ADRENO, "flushall,syncdraw", false);

    companion object {
        /** The fixes [family]'s driver has. */
        fun of(family: GpuFamily): List<GpuFix> = entries.filter { it.family == family }
    }
}
