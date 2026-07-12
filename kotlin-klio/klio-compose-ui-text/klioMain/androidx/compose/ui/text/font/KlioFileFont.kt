/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.text.font

import androidx.compose.ui.text.platform.__skia_font_register

/**
 * A [Font] backed by a font FILE on disk (TTF/OTF). With a Skia backend the
 * file's typeface registers in the paragraph font provider under a
 * path-derived family alias, so runs naming the family shape with the real
 * face; headless the alias falls back to the deterministic bundled metrics.
 */
class KlioFileFont(
    val path: String,
    override val weight: FontWeight = FontWeight.Normal,
    override val style: FontStyle = FontStyle.Normal,
) : Font {
    override val loadingStrategy: FontLoadingStrategy
        get() = FontLoadingStrategy.Blocking

    internal val familyAlias: String = "klio-file:" + path

    internal companion object {
        private val registered = HashSet<String>()

        /** Register [font]'s file in the native provider once; returns the
         * family alias to put in the run spec (whether or not a backend is
         * present — headless simply never matches it). */
        fun aliasFor(font: KlioFileFont): String {
            if (registered.add(font.familyAlias)) {
                __skia_font_register(font.path, font.familyAlias)
            }
            return font.familyAlias
        }
    }
}

/** A file-backed [Font] (klio platform form of the desktop `Font(File)`). */
fun Font(
    path: String,
    weight: FontWeight = FontWeight.Normal,
    style: FontStyle = FontStyle.Normal,
): Font = KlioFileFont(path, weight, style)
