// org.jetbrains.skia's platform half on klio: the symbol-name annotation its
// natives carry, the locale, java.util.regex's Pattern and Matcher over
// Kotlin's Regex, and the peers whose natives call back into Kotlin.
package org.jetbrains.skia

import org.jetbrains.skia.impl.NativePointer
import org.jetbrains.skia.impl.Native
import org.jetbrains.skia.impl.NO_CALLBACKS
import org.jetbrains.skia.impl.withStringReferenceResult

/** The C symbol a native is bound to: the one skiko's glue exports it under. */
@Target(AnnotationTarget.FUNCTION)
actual annotation class ExternalSymbolName(actual val name: String)

internal actual fun <R> commonSynchronized(lock: Any, block: () -> R) {
    block()
}

/** The host's locale, as the JVM's default locale is. */
internal actual fun defaultLanguageTag(): String = __skiko_defaultLanguageTag()

internal fun __skiko_defaultLanguageTag(): String = error("intrinsic org.jetbrains.skia.__skiko_defaultLanguageTag is not installed")

actual class Pattern internal constructor(private val regex: Regex) {
    /** As java.util.regex.Pattern.split: trailing empty strings are dropped. */
    actual fun split(input: CharSequence): Array<String> {
        val parts = regex.split(input).toMutableList()
        while (parts.size > 1 && parts.last().isEmpty()) parts.removeAt(parts.size - 1)
        return parts.toTypedArray()
    }

    actual fun matcher(input: CharSequence): Matcher = Matcher(regex, input)
}

actual class Matcher internal constructor(private val regex: Regex, private val input: CharSequence) {
    private var match: MatchResult? = null

    /** The group's text, or null when it took no part in the match. */
    actual fun group(ix: Int): String? {
        val m = match ?: throw IllegalStateException("No match found")
        return m.groups[ix]?.value
    }

    actual fun matches(): Boolean {
        match = regex.matchEntire(input)
        return match != null
    }
}

internal actual fun compilePattern(regex: String): Pattern = Pattern(Regex(regex))

internal actual fun RuntimeEffect.Companion.makeFromResultPtr(ptr: NativePointer): RuntimeEffect {
    val errorPtr = Result_nGetError(ptr)
    if (errorPtr != Native.NullPointer) {
        val error = withStringReferenceResult { errorPtr }
        Result_nDestroy(ptr)
        throw RuntimeException(error)
    }
    val effect = Result_nGetPtr(ptr)
    Result_nDestroy(ptr)
    return RuntimeEffect(effect)
}

internal actual fun Drawable.doInit(ptr: NativePointer) {
    throw UnsupportedOperationException(NO_CALLBACKS)
}

internal actual fun PaintFilterCanvas.doInit(ptr: NativePointer) {
    throw UnsupportedOperationException(NO_CALLBACKS)
}
