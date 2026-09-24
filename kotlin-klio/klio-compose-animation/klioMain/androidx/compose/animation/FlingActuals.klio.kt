/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.animation

import androidx.compose.animation.core.DecayAnimationSpec
import androidx.compose.animation.core.generateDecayAnimationSpec
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalDensity

// ViewConfiguration.getScrollFriction's platform constant (0.015f on both
// android and desktop upstream actuals).
internal actual val platformFlingScrollFriction: Float = 0.015f

// The desktop actuals: the spline decay for the composition's density,
// recomputed only when the density changes.
@Composable
public actual fun <T> rememberSplineBasedDecay(): DecayAnimationSpec<T> {
    val density = LocalDensity.current
    return remember(density.density) {
        SplineBasedFloatDecayAnimationSpec(density).generateDecayAnimationSpec()
    }
}

@Composable
@Deprecated("Replace with rememberSplineBasedDecay<Float>")
public actual fun defaultDecayAnimationSpec(): DecayAnimationSpec<Float> =
    rememberSplineBasedDecay()
