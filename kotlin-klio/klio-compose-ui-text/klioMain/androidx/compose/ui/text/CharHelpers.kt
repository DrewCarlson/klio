/*
 * Copyright 2023 The Android Open Source Project
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

package androidx.compose.ui.text

// klio does not have ICU BreakIterator; approximate character (grapheme) boundaries
// at the code-point level, keeping surrogate pairs together. Returns -1 when there is
// no boundary in the requested direction.

internal actual fun String.findPrecedingBreak(index: Int): Int {
    if (index <= 0) return -1
    var i = index - 1
    if (i > 0 && this[i].isLowSurrogate() && this[i - 1].isHighSurrogate()) {
        i -= 1
    }
    return i
}

internal actual fun String.findFollowingBreak(index: Int): Int {
    if (index >= length) return -1
    var i = index + 1
    if (i < length && this[index].isHighSurrogate() && this[i].isLowSurrogate()) {
        i += 1
    }
    return i
}
