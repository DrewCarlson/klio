/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package org.jetbrains.skia.icu

/**
 * klio's stand-in for the skia ICU character properties foundation's
 * StringHelpers.skiko.kt asks about emoji. The property ids are ICU's UProperty
 * values. klio has no ICU property data. The emoji check runs only when a
 * character break falls before the previous code point, which klio's code point
 * breaks never produce. Internal to the pack: it is not the skia API.
 */
internal object CharProperties {
    const val EMOJI_PRESENTATION: Int = 58
    const val EXTENDED_PICTOGRAPHIC: Int = 64

    fun codePointHasBinaryProperty(codePoint: Int, property: Int): Boolean =
        throw UnsupportedOperationException("klio: ICU character properties are not available")
}
