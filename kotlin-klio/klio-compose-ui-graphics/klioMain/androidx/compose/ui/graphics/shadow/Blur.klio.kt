/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics.shadow

import androidx.compose.ui.graphics.KlioPaint
import androidx.compose.ui.graphics.Paint

/**
 * A shadow's blur: the normal-style Gaussian mask filter of [sigma]. skiko's
 * is a Skia `MaskFilter` (Blur.skiko.kt); klio's canvas hands the sigma to
 * its Skia shim, which makes the same filter for the draw.
 */
internal actual class BlurFilter internal constructor(internal val radius: Float, internal val sigma: Float)

/** The blur of [radius], its sigma converted as skiko converts it. */
internal actual fun BlurFilter(radius: Float): BlurFilter =
    BlurFilter(radius, if (radius > 0) BlurSigmaScale * radius + 0.5f else 0.0f)

internal actual fun Paint.setBlurFilter(blur: BlurFilter?) {
    (this as KlioPaint).blurFilter = blur
}

// Skia's scale from a blur radius to its Gaussian sigma (1 / sqrt(3)), which
// skiko's BlurEffect.convertRadiusToSigma uses.
private const val BlurSigmaScale = 0.57735f
