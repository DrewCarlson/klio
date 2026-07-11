/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.gestures

import androidx.compose.ui.input.pointer.PointerEvent

/** klio actual: pointer streams carry no deep-press classification. */
internal actual val PointerEvent.isDeepPress: Boolean
    get() = false
