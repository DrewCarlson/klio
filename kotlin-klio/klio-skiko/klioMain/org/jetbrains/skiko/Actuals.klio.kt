// org.jetbrains.skiko's platform half on klio: the host's OS and architecture,
// time, resources, the GL and ANGLE loaders, and SkiaLayer. A SkiaLayer is the
// JVM's and the native platforms' view onto a window; klio's windows draw
// their Compose scenes through the Skia shim themselves, so a layer draws only
// where it is asked to and cannot be attached to a window.
package org.jetbrains.skiko

import kotlin.time.TimeSource
import org.jetbrains.skia.Canvas
import org.jetbrains.skia.PixelGeometry

internal actual inline fun <R> maybeSynchronized(lock: Any, block: () -> R): R = block()

private val nanoStart = TimeSource.Monotonic.markNow()

/** Monotonic nanoseconds, as System.nanoTime is: only differences mean anything. */
actual fun currentNanoTime(): Long = nanoStart.elapsedNow().inWholeNanoseconds

actual val hostOs: OS = when (__skiko_hostOs()) {
    "macos" -> OS.MacOS
    "linux" -> OS.Linux
    "windows" -> OS.Windows
    else -> OS.Unknown
}

actual val hostArch: Arch = when (__skiko_hostArch()) {
    "x64" -> Arch.X64
    "arm64" -> Arch.Arm64
    else -> Arch.Unknown
}

actual val hostId: String = "${hostOs.id}-${hostArch.id}"

actual val kotlinBackend: KotlinBackend = KotlinBackend.Native

/** klio has no reading of the system's appearance; Compose then uses its light theme. */
actual val currentSystemTheme: SystemTheme = SystemTheme.UNKNOWN

actual suspend fun loadBytesFromPath(path: String): ByteArray = __skiko_readFile(path)

internal actual fun loadAngleLibrary() {
    throw RenderException("ANGLE is not available on klio")
}

/** The Skia shim links the platform's GL runtime where it uses one. */
internal actual fun loadOpenGLLibrary() {}

actual open class SkiaLayer {
    actual var renderApi: GraphicsApi = GraphicsApi.SOFTWARE_FAST

    actual val contentScale: Float get() = 1f

    actual val pixelGeometry: PixelGeometry get() = PixelGeometry.UNKNOWN

    actual var fullscreen: Boolean = false

    actual val component: Any? get() = null

    actual var renderDelegate: SkikoRenderDelegate? = null

    actual fun attachTo(container: Any) {
        throw UnsupportedOperationException("a SkiaLayer cannot be attached to a window on klio")
    }

    actual fun detach() {}

    actual fun needRender(throttledToVsync: Boolean) {}

    @Deprecated(
        message = "Use needRender() instead",
        replaceWith = ReplaceWith("needRender()")
    )
    actual fun needRedraw() = needRender()

    internal actual fun draw(canvas: Canvas) {
        renderDelegate?.onRender(canvas, 0, 0, currentNanoTime())
    }
}

internal fun __skiko_hostOs(): String = error("intrinsic org.jetbrains.skiko.__skiko_hostOs is not installed")
internal fun __skiko_hostArch(): String = error("intrinsic org.jetbrains.skiko.__skiko_hostArch is not installed")
internal fun __skiko_readFile(path: String): ByteArray = error("intrinsic org.jetbrains.skiko.__skiko_readFile is not installed")
