// skiko's font resolution (SkiaFontLoader.skiko.kt, FontFamilyResolver.skiko.kt,
// PlatformFontFamilyTypefaceAdapter.skiko.kt) over the Skia shim: resolving a
// font family answers the family names a run shapes with, as skiko's
// FontLoadResult's aliases. A generic or the default family answers its
// generic name, which the shim maps to the platform's fonts; a SystemFont its
// family name; a LoadedFont or a file font the name its bytes are registered
// under.
package androidx.compose.ui.text.font

import androidx.compose.ui.text.ExperimentalTextApi
import androidx.compose.ui.text.font.FontLoadingStrategy.Companion.Async
import androidx.compose.ui.text.font.FontLoadingStrategy.Companion.Blocking
import androidx.compose.ui.text.font.FontLoadingStrategy.Companion.OptionalLocal
import androidx.compose.ui.text.platform.LoadedFont
import androidx.compose.ui.text.platform.PlatformFont
import androidx.compose.ui.text.platform.SystemFont
import androidx.compose.ui.text.platform.__skia_font_register_data
import kotlin.coroutines.CoroutineContext

/** What a font resolves to: the family names a run lists, in order. */
internal class KlioFontLoadResult(val aliases: List<String>)

/** The families a program's loaded fonts are registered under, once each. */
private val registeredFonts = HashSet<String>()

@OptIn(ExperimentalTextApi::class)
internal class KlioFontLoader : PlatformFontLoader {
    override fun loadBlocking(font: Font): KlioFontLoadResult? {
        if (font is KlioFileFont) return KlioFontLoadResult(listOf(KlioFileFont.aliasFor(font)))
        if (font !is PlatformFont) {
            if (font.loadingStrategy != OptionalLocal) {
                throw IllegalArgumentException("Unsupported font type: $font")
            }
            return null
        }
        return when (font.loadingStrategy) {
            Blocking -> load(font)
            OptionalLocal -> kotlin.runCatching { load(font) }.getOrNull()
            Async -> throw UnsupportedOperationException("Unsupported Async font load path")
            else -> throw IllegalArgumentException(
                "Unknown loading type ${font.loadingStrategy}"
            )
        }
    }

    internal fun load(font: PlatformFont): KlioFontLoadResult = when (font) {
        is SystemFont -> KlioFontLoadResult(listOf(font.identity))
        is LoadedFont -> {
            val key = font.cacheKey
            if (registeredFonts.add(key)) __skia_font_register_data(font.data, key)
            KlioFontLoadResult(listOf(key))
        }
    }

    fun loadPlatformTypes(fontFamily: FontFamily): KlioFontLoadResult = when (fontFamily) {
        is GenericFontFamily -> KlioFontLoadResult(listOf(fontFamily.name))
        is FontListFontFamily -> KlioFontLoadResult(
            fontFamily.fonts.mapNotNull { (it as? SystemFont)?.identity }
        )
        else -> KlioFontLoadResult(listOf(FontFamily.SansSerif.name))
    }

    override suspend fun awaitLoad(font: Font): KlioFontLoadResult? = loadBlocking(font)

    override val cacheKey: Any? = null
}

fun createFontFamilyResolver(): FontFamily.Resolver = FontFamilyResolverImpl(KlioFontLoader())

@ExperimentalTextApi
fun createFontFamilyResolver(
    coroutineContext: CoroutineContext
): FontFamily.Resolver {
    return FontFamilyResolverImpl(
        KlioFontLoader(),
        PlatformResolveInterceptor.Default,
        GlobalTypefaceRequestCache,
        FontListFontFamilyTypefaceAdapter(
            GlobalAsyncTypefaceCache,
            coroutineContext
        )
    )
}

@Suppress("DEPRECATION", "KmpDeprecationMismatch")
internal actual fun createFontFamilyResolver(
    fontResourceLoader: Font.ResourceLoader
): FontFamily.Resolver = createFontFamilyResolver()

// Skia synthesizes no bold or italic here; the resolved family is used as is.
internal actual fun FontSynthesis.synthesizeTypeface(
    typeface: Any,
    font: Font,
    requestedWeight: FontWeight,
    requestedStyle: FontStyle,
): Any = typeface

internal actual class PlatformFontFamilyTypefaceAdapter actual constructor() :
    FontFamilyTypefaceAdapter {

    actual override fun resolve(
        typefaceRequest: TypefaceRequest,
        platformFontLoader: PlatformFontLoader,
        onAsyncCompletion: (TypefaceResult.Immutable) -> Unit,
        createDefaultTypeface: (TypefaceRequest) -> Any,
    ): TypefaceResult? {
        if (typefaceRequest.fontFamily is FontListFontFamily) return null
        val loader = platformFontLoader as KlioFontLoader
        return TypefaceResult.Immutable(
            loader.loadPlatformTypes(typefaceRequest.fontFamily ?: FontFamily.Default)
        )
    }
}
