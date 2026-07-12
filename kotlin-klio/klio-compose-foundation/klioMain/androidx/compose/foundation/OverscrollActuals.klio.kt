/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation

import androidx.compose.runtime.CompositionLocalAccessorScope

// Desktop compose ships no overscroll effect; scrolling components see a null
// factory and skip the overscroll pipeline entirely.
internal actual fun CompositionLocalAccessorScope.defaultOverscrollFactory(): OverscrollFactory? = null
