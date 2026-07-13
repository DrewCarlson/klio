/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.text.selection

import androidx.compose.ui.graphics.Color

/**
 * klio actual for the default text-selection colours.
 *
 * Desktop Compose uses the same values Android's material defaults do: the
 * handle takes the primary colour, and the selection background is that colour
 * at 40% alpha (the ratio upstream picks so text stays legible under the
 * highlight).
 */
private val DefaultSelectionColor = Color(0xFF4286F4)

internal actual val DefaultTextSelectionColors: TextSelectionColors =
    TextSelectionColors(
        handleColor = DefaultSelectionColor,
        backgroundColor = DefaultSelectionColor.copy(alpha = 0.4f),
    )
