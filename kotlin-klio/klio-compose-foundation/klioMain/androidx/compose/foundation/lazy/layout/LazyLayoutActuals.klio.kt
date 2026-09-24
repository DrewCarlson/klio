/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.lazy.layout

// The stable fallback key for an item with no user-provided key: equal for
// equal indices across compositions (the skiko actual's shape).
private data class DefaultLazyKey(private val index: Int)

actual fun getDefaultLazyLayoutKey(index: Int): Any = DefaultLazyKey(index)
