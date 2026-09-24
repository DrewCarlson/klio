/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.lifecycle.compose

import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.lifecycle.LifecycleOwner

/**
 * lifecycle-runtime-compose's lifecycle owner local, beside the lifecycle slice
 * this pack carries; the ui module's deprecated LocalLifecycleOwner forwards to
 * it. As off Android upstream, nothing is provided by default.
 */
public val LocalLifecycleOwner: ProvidableCompositionLocal<LifecycleOwner> =
    staticCompositionLocalOf {
        error("CompositionLocal LocalLifecycleOwner not present")
    }
