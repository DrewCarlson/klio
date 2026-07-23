package androidx.compose.material3.internal

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.runtime.Composable

internal actual val WindowInsets.Companion.systemBarsForVisualComponents: WindowInsets
    @Composable get() = WindowInsets(0, 0, 0, 0)
