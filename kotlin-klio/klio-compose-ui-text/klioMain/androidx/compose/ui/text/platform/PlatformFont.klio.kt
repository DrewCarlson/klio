/*
 * Copyright 2021 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// The skiko fonts of PlatformFont.skiko.kt, with the desktop's PlatformFont
// (DesktopFont.desktop.kt): a SystemFont names a family the platform's font
// manager has, and a LoadedFont carries a font file's bytes, which the Skia
// shim registers under the font's cache key the first time a run shapes
// with it.
package androidx.compose.ui.text.platform

import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontLoadingStrategy
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight

sealed class PlatformFont : Font {
    abstract val identity: String
    abstract val variationSettings: FontVariation.Settings
    internal val cacheKey: String
        get() = "${this::class.qualifiedName}|$identity|weight=${weight.weight}|style=$style"
}

/**
 * Defines a Font using a system font family name.
 *
 * @param identity Unique identity for a font. Used internally to distinguish fonts.
 * @param weight The weight of the font. The system uses this to match a font to a font request
 * that is given in a [androidx.compose.ui.text.SpanStyle].
 * @param style The style of the font, normal or italic. The system uses this to match a font to a
 * font request that is given in a [androidx.compose.ui.text.SpanStyle].
 *
 * @see FontFamily
 */
@ExperimentalTextApi
class SystemFont(
    override val identity: String,
    override val weight: FontWeight = FontWeight.Normal,
    override val style: FontStyle = FontStyle.Normal,
    override val variationSettings: FontVariation.Settings = FontVariation.Settings(weight, style),
) : PlatformFont() {

    constructor(
        identity: String,
        weight: FontWeight = FontWeight.Normal,
        style: FontStyle = FontStyle.Normal
    ) : this(identity, weight, style, variationSettings = FontVariation.Settings())

    override fun toString(): String {
        return "SystemFont(identity='$identity', weight=$weight, style=$style, variationSettings=${variationSettings.settings})"
    }
}

/**
 * Defines a Font using byte array with loaded font data.
 *
 * @param identity Unique identity for a font. Used internally to distinguish fonts.
 * @param getData should return Byte array with loaded font data.
 * @param weight The weight of the font. The system uses this to match a font to a font request
 * that is given in a [androidx.compose.ui.text.SpanStyle].
 * @param style The style of the font, normal or italic. The system uses this to match a font to a
 * font request that is given in a [androidx.compose.ui.text.SpanStyle].
 *
 * @see FontFamily
 */
class LoadedFont internal constructor(
    override val identity: String,
    internal val getData: () -> ByteArray,
    override val weight: FontWeight,
    override val style: FontStyle,
    override val variationSettings: FontVariation.Settings = FontVariation.Settings(weight, style),
) : PlatformFont() {

    constructor(
        identity: String,
        getData: () -> ByteArray,
        weight: FontWeight,
        style: FontStyle
    ) : this(identity, getData, weight, style, FontVariation.Settings())

    @ExperimentalTextApi
    override val loadingStrategy: FontLoadingStrategy = FontLoadingStrategy.Blocking

    val data: ByteArray get() = getData()

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is LoadedFont) return false
        if (identity != other.identity) return false
        if (weight != other.weight) return false
        if (style != other.style) return false
        return variationSettings.settings == other.variationSettings.settings
    }

    override fun hashCode(): Int {
        var result = identity.hashCode()
        return result
    }

    override fun toString(): String {
        return "LoadedFont(identity='$identity', weight=$weight, style=$style, variationSettings=${variationSettings.settings})"
    }
}

/**
 * Creates a Font using byte array with loaded font data.
 *
 * @param identity Unique identity for a font. Used internally to distinguish fonts.
 * @param getData should return Byte array with loaded font data.
 * @param weight The weight of the font. The system uses this to match a font to a font request
 * that is given in a [androidx.compose.ui.text.SpanStyle].
 * @param style The style of the font, normal or italic. The system uses this to match a font to a
 * font request that is given in a [androidx.compose.ui.text.SpanStyle].
 *
 * @see FontFamily
 */
fun Font(
    identity: String,
    getData: () -> ByteArray,
    weight: FontWeight = FontWeight.Normal,
    style: FontStyle = FontStyle.Normal
): Font = LoadedFont(identity, getData, weight, style, FontVariation.Settings())

/**
 * Creates a Font using byte array with loaded font data.
 *
 * @param identity Unique identity for a font. Used internally to distinguish fonts.
 * @param getData should return Byte array with loaded font data.
 * @param weight The weight of the font. The system uses this to match a font to a font request
 * that is given in a [androidx.compose.ui.text.SpanStyle].
 * @param style The style of the font, normal or italic. The system uses this to match a font to a
 * font request that is given in a [androidx.compose.ui.text.SpanStyle].
 * @param variationSettings The variation settings for this font.
 *
 * @see FontFamily
 */
fun Font(
    identity: String,
    getData: () -> ByteArray,
    weight: FontWeight = FontWeight.Normal,
    style: FontStyle = FontStyle.Normal,
    variationSettings: FontVariation.Settings = FontVariation.Settings(weight, style)
): Font = LoadedFont(identity, getData, weight, style, variationSettings)

/**
 * Creates a Font using byte array with loaded font data.
 *
 * @param identity Unique identity for a font. Used internally to distinguish fonts.
 * @param data Byte array with loaded font data.
 * @param weight The weight of the font. The system uses this to match a font to a font request
 * that is given in a [androidx.compose.ui.text.SpanStyle].
 * @param style The style of the font, normal or italic. The system uses this to match a font to a
 * font request that is given in a [androidx.compose.ui.text.SpanStyle].
 *
 * @see FontFamily
 */
fun Font(
    identity: String,
    data: ByteArray,
    weight: FontWeight = FontWeight.Normal,
    style: FontStyle = FontStyle.Normal
): Font = Font(
    identity = identity,
    getData = { data },
    weight = weight,
    style = style,
    variationSettings = FontVariation.Settings(),
)

/**
 * Creates a Font using byte array with loaded font data.
 *
 * @param identity Unique identity for a font. Used internally to distinguish fonts.
 * @param data Byte array with loaded font data.
 * @param weight The weight of the font. The system uses this to match a font to a font request
 * that is given in a [androidx.compose.ui.text.SpanStyle].
 * @param style The style of the font, normal or italic. The system uses this to match a font to a
 * font request that is given in a [androidx.compose.ui.text.SpanStyle].
 * @param variationSettings The variation settings for this font.
 *
 * @see FontFamily
 */
fun Font(
    identity: String,
    data: ByteArray,
    weight: FontWeight = FontWeight.Normal,
    style: FontStyle = FontStyle.Normal,
    variationSettings: FontVariation.Settings = FontVariation.Settings(weight, style)
): Font = Font(
    identity = identity,
    getData = { data },
    weight = weight,
    style = style,
    variationSettings = variationSettings,
)

/** Registers a loaded font's bytes under [family]; false headless or for bytes that do not load. */
/**
 * skiko's deprecated font loader: it loads a [PlatformFont] for the paragraph
 * layer, answering what a run shapes it with (the families skiko's
 * FontLoadResult names) where skiko's answers the skia Typeface.
 */
@Suppress("DEPRECATION", "OverridingDeprecatedMember")
@Deprecated(
    "Replaced with PlatformFontLoader during the introduction of async fonts, all usages" +
        " should be replaced",
    ReplaceWith("PlatformFontLoader"),
)
class FontLoader : Font.ResourceLoader {
    private val loader = androidx.compose.ui.text.font.KlioFontLoader()

    @Deprecated(
        "Replaced by FontFamily.Resolver, this method should not be called",
        ReplaceWith("FontFamily.Resolver.resolve(font, )"),
    )
    override fun load(font: Font): Any {
        if (font !is PlatformFont) {
            throw IllegalArgumentException("Unsupported font type: $font")
        }
        return loader.load(font)
    }
}

internal fun __skia_font_register_data(data: ByteArray, family: String): Boolean = false
