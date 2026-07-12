/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.lazy

import androidx.compose.runtime.Composable

// Desktop composes no extra beyond-bounds items by default (the android
// actual reserves one for focus-search; desktop matches the skiko actual).
@Composable internal actual fun defaultLazyListBeyondBoundsItemCount(): Int = 0
