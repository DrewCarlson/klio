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

package androidx.compose.ui.text.font

// klio's Skia shim renders every run with one bundled font (it ignores per-family
// / per-weight typeface requests), so font resolution here is uniform: any
// FontFamily resolves to the single [KlioTypeface] marker. The real layout +
// glyph work happens in KlioParagraph, keyed only by pixel size. This is the
// desktop actual for the ui-text font-resolution `expect`s.

/** The one typeface klio's shim draws with; a marker (the shim needs no handle). */
internal object KlioTypeface

/**
 * A [PlatformFontLoader] that resolves every [Font] to [KlioTypeface]. `cacheKey`
 * is null: results never differ from the platform default, so no per-loader
 * cache partitioning is needed.
 */
internal class KlioFontLoader : PlatformFontLoader {
    override fun loadBlocking(font: Font): Any = KlioTypeface

    override suspend fun awaitLoad(font: Font): Any = KlioTypeface

    override val cacheKey: Any? = null
}

/**
 * Create a font resolver for use outside a composition (background layout,
 * preloading). Reuses the real [FontFamilyResolverImpl] dispatch; only the
 * platform loader + the non-list typeface adapter are klio's.
 */
fun createFontFamilyResolver(): FontFamily.Resolver = FontFamilyResolverImpl(KlioFontLoader())

@Suppress("DEPRECATION", "KmpDeprecationMismatch")
internal actual fun createFontFamilyResolver(
    fontResourceLoader: Font.ResourceLoader
): FontFamily.Resolver = createFontFamilyResolver()

// klio uses the bundled font as-is; synthetic bold/italic transforms are not
// applied, so synthesis returns the resolved typeface unchanged.
internal actual fun FontSynthesis.synthesizeTypeface(
    typeface: Any,
    font: Font,
    requestedWeight: FontWeight,
    requestedStyle: FontStyle,
): Any = typeface

// Resolves every non-FontListFontFamily request (Default, Generic, loaded) to the
// bundled typeface. FontListFontFamily is handled upstream by
// FontListFontFamilyTypefaceAdapter before this adapter is consulted.
internal actual class PlatformFontFamilyTypefaceAdapter actual constructor() :
    FontFamilyTypefaceAdapter {

    actual override fun resolve(
        typefaceRequest: TypefaceRequest,
        platformFontLoader: PlatformFontLoader,
        onAsyncCompletion: (TypefaceResult.Immutable) -> Unit,
        createDefaultTypeface: (TypefaceRequest) -> Any,
    ): TypefaceResult = TypefaceResult.Immutable(KlioTypeface)
}
