package androidx.compose.runtime

import kotlin.time.TimeSource
import kotlinx.coroutines.delay

/**
 * The desktop's default frame clock (ActualDesktop.desktop.kt): a frame every
 * sixtieth of a second, timed by a monotonic clock. Desktop reads
 * `System.nanoTime()`; klio reads the nanoseconds since the clock's first
 * use, which is as arbitrary an origin.
 */
@Deprecated(
    "MonotonicFrameClocks are not globally applicable across platforms. " +
        "Use an appropriate local clock."
)
public actual val DefaultMonotonicFrameClock: MonotonicFrameClock
    get() = SixtyFpsMonotonicFrameClock

private object SixtyFpsMonotonicFrameClock : MonotonicFrameClock {
    private const val fps = 60
    private val origin = TimeSource.Monotonic.markNow()

    override suspend fun <R> withFrameNanos(onFrame: (Long) -> R): R {
        delay(1000L / fps)
        return onFrame(origin.elapsedNow().inWholeNanoseconds)
    }
}
