/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.foundation.text.input.internal

/** The number of `Char`s a code point occupies: 2 above the BMP, 1 otherwise. */
internal actual fun charCount(codePoint: Int): Int = if (codePoint >= 0x10000) 2 else 1
