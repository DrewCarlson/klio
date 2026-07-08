package androidx.compose.animation.core.internal

import kotlinx.coroutines.CancellationException

internal actual abstract class PlatformOptimizedCancellationException actual constructor(
    message: String?,
) : CancellationException(message)
