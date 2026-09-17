/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.animation

// ViewConfiguration.getScrollFriction's platform constant (0.015f on both
// android and desktop upstream actuals).
internal actual val platformFlingScrollFriction: Float = 0.015f
