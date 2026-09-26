// The shaper's run handlers are Kotlin objects the native shaper calls back.
package org.jetbrains.skia.shaper

import org.jetbrains.skia.ManagedString
import org.jetbrains.skia.impl.NO_CALLBACKS

internal actual fun Shaper.doShape(
    textUtf8: ManagedString,
    fontIter: Iterator<FontRun?>,
    bidiIter: Iterator<BidiRun?>,
    scriptIter: Iterator<ScriptRun?>,
    langIter: Iterator<LanguageRun?>,
    opts: ShapingOptions,
    width: Float,
    runHandler: RunHandler,
) {
    throw UnsupportedOperationException(NO_CALLBACKS)
}
