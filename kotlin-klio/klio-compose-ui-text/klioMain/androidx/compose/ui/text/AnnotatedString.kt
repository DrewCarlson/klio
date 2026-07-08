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

package androidx.compose.ui.text

/**
 * The core function of [AnnotatedString] transformation.
 *
 * Transforms the text one style/annotation run at a time so that the offsets of every
 * annotation can be remapped onto the (possibly re-sized) transformed text.
 */
internal actual fun AnnotatedString.transform(
    transform: (String, Int, Int) -> String
): AnnotatedString {
    // Every offset where an annotation run begins or ends, plus the two text
    // endpoints. Each adjacent pair delimits a contiguous run to transform.
    val boundarySet = LinkedHashSet<Int>()
    boundarySet.add(0)
    boundarySet.add(text.length)
    annotations?.forEach { range ->
        boundarySet.add(range.start.coerceIn(0, text.length))
        boundarySet.add(range.end.coerceIn(0, text.length))
    }
    val boundaries = boundarySet.toIntArray()
    boundaries.sort()

    val builder = StringBuilder()
    val offsetMap = HashMap<Int, Int>()
    offsetMap[boundaries[0]] = 0
    for (i in 0 until boundaries.size - 1) {
        val start = boundaries[i]
        val end = boundaries[i + 1]
        builder.append(transform(text, start, end))
        offsetMap[end] = builder.length
    }
    val resultStr = builder.toString()

    val newAnnotations = annotations?.map { range ->
        AnnotatedString.Range(
            range.item,
            offsetMap[range.start.coerceIn(0, text.length)] ?: range.start,
            offsetMap[range.end.coerceIn(0, text.length)] ?: range.end,
            range.tag
        )
    }
    return AnnotatedString(annotations = newAnnotations, text = resultStr)
}
