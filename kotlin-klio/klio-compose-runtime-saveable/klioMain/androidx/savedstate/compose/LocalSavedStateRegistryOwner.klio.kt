/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.savedstate.compose

import androidx.compose.runtime.ProvidableCompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.savedstate.SavedStateRegistryOwner

public val LocalSavedStateRegistryOwner: ProvidableCompositionLocal<SavedStateRegistryOwner> =
    staticCompositionLocalOf {
        error("CompositionLocal LocalSavedStateRegistryOwner not present")
    }
