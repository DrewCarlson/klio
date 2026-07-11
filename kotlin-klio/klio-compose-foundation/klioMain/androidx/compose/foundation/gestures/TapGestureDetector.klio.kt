/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.gestures

/**
 * klio actual (desktop semantics): a first-down gesture responds only to
 * the primary mouse button, matching the desktop targets.
 */
internal actual fun firstDownRefersToPrimaryMouseButtonOnly(): Boolean = true
