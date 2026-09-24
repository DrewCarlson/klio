/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package org.jetbrains.skia

/**
 * klio's stand-in for the skia (ICU) BreakIterator members foundation's
 * StringHelpers.skiko.kt calls. klio has no ICU, so a character instance
 * breaks at code points, keeping surrogate pairs together: the same
 * approximation klio's ui-text actuals make for grapheme boundaries. As in
 * ICU, the iterator has a current boundary: [setText] puts it at the start,
 * [next] advances it, and [preceding] and [following] move it to their answer.
 * Internal to the pack: it serves the vendored skiko sources, it is not the
 * skia API.
 */
internal class BreakIterator private constructor() {
    private var text: String = ""
    private var current: Int = 0

    fun setText(text: String?) {
        this.text = text ?: ""
        current = 0
    }

    /** The boundary after the current one, which becomes current; [DONE] at the end. */
    fun next(): Int {
        if (current >= text.length) return DONE
        current = boundaryAfter(current)
        return current
    }

    /** The last boundary before [offset], or [DONE]. */
    fun preceding(offset: Int): Int {
        val index = offset.coerceAtMost(text.length)
        if (index <= 0) {
            current = 0
            return DONE
        }
        var i = index - 1
        if (i > 0 && text[i].isLowSurrogate() && text[i - 1].isHighSurrogate()) i -= 1
        current = i
        return i
    }

    /** The first boundary after [offset], or [DONE]. */
    fun following(offset: Int): Int {
        val index = offset.coerceAtLeast(0)
        if (index >= text.length) {
            current = text.length
            return DONE
        }
        current = boundaryAfter(index)
        return current
    }

    private fun boundaryAfter(index: Int): Int {
        var i = index + 1
        if (i < text.length && text[index].isHighSurrogate() && text[i].isLowSurrogate()) i += 1
        return i
    }

    companion object {
        const val DONE: Int = -1

        fun makeCharacterInstance(locale: String? = null): BreakIterator = BreakIterator()
    }
}
