/*
 * Copyright 2020 The Android Open Source Project
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

// Compose 1.12.0 made the `Paragraph` and `ParagraphIntrinsics` factories the
// expect declarations themselves; the older `ActualParagraph` indirection is gone.
// Every overload lands on KlioParagraph / KlioParagraphIntrinsics.

package androidx.compose.ui.text

import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.platform.KlioParagraph
import androidx.compose.ui.text.platform.KlioParagraphIntrinsics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import kotlin.math.ceil

private fun widthConstraints(width: Float): Constraints =
    Constraints(maxWidth = ceil(width).toInt())

private fun intrinsicsOf(paragraphIntrinsics: ParagraphIntrinsics): KlioParagraphIntrinsics =
    paragraphIntrinsics as KlioParagraphIntrinsics

private fun paragraph(
    text: String,
    style: TextStyle,
    density: Density,
    maxLines: Int,
    overflow: TextOverflow,
    constraints: Constraints,
    annotations: List<AnnotatedString.Range<out AnnotatedString.Annotation>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
): Paragraph =
    KlioParagraph(
        text,
        style,
        density,
        maxLines,
        ellipsis = overflow == TextOverflow.Ellipsis,
        width = constraints.maxWidth.toFloat(),
        annotations = annotations,
        placeholders = placeholders,
    )

@Suppress("DEPRECATION", "KmpDeprecationMismatch")
@Deprecated("Font.ResourceLoader is deprecated, instead pass FontFamily.Resolver")
actual fun Paragraph(
    text: String,
    style: TextStyle,
    spanStyles: List<AnnotatedString.Range<SpanStyle>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    maxLines: Int,
    ellipsis: Boolean,
    width: Float,
    density: Density,
    resourceLoader: Font.ResourceLoader,
): Paragraph =
    paragraph(
        text,
        style,
        density,
        maxLines,
        if (ellipsis) TextOverflow.Ellipsis else TextOverflow.Clip,
        widthConstraints(width),
        spanStyles,
        placeholders,
    )

@Suppress("DEPRECATION", "KmpDeprecationMismatch")
@Deprecated(
    "Paragraph that takes maximum allowed width is deprecated, pass constraints instead."
)
actual fun Paragraph(
    text: String,
    style: TextStyle,
    width: Float,
    density: Density,
    fontFamilyResolver: FontFamily.Resolver,
    spanStyles: List<AnnotatedString.Range<SpanStyle>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    maxLines: Int,
    ellipsis: Boolean,
): Paragraph =
    paragraph(
        text,
        style,
        density,
        maxLines,
        if (ellipsis) TextOverflow.Ellipsis else TextOverflow.Clip,
        widthConstraints(width),
        spanStyles,
        placeholders,
    )

@Suppress("DEPRECATION", "KmpDeprecationMismatch")
@Deprecated(
    "Paragraph that takes `ellipsis: Boolean` is deprecated, pass TextOverflow instead.",
    level = DeprecationLevel.HIDDEN,
)
actual fun Paragraph(
    text: String,
    style: TextStyle,
    constraints: Constraints,
    density: Density,
    fontFamilyResolver: FontFamily.Resolver,
    spanStyles: List<AnnotatedString.Range<SpanStyle>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    maxLines: Int,
    ellipsis: Boolean,
): Paragraph =
    paragraph(
        text,
        style,
        density,
        maxLines,
        if (ellipsis) TextOverflow.Ellipsis else TextOverflow.Clip,
        constraints,
        spanStyles,
        placeholders,
    )

actual fun Paragraph(
    text: String,
    style: TextStyle,
    constraints: Constraints,
    density: Density,
    fontFamilyResolver: FontFamily.Resolver,
    spanStyles: List<AnnotatedString.Range<SpanStyle>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    maxLines: Int,
    overflow: TextOverflow,
): Paragraph =
    paragraph(
        text,
        style,
        density,
        maxLines,
        overflow,
        constraints,
        spanStyles,
        placeholders,
    )

@Suppress("DEPRECATION", "KmpDeprecationMismatch")
@Deprecated(
    "Paragraph that takes maximum allowed width is deprecated, pass constraints instead."
)
actual fun Paragraph(
    paragraphIntrinsics: ParagraphIntrinsics,
    maxLines: Int,
    ellipsis: Boolean,
    width: Float,
): Paragraph {
    val i = intrinsicsOf(paragraphIntrinsics)
    return paragraph(
        i.text,
        i.style,
        i.density,
        maxLines,
        if (ellipsis) TextOverflow.Ellipsis else TextOverflow.Clip,
        widthConstraints(width),
        i.annotations,
        i.placeholders,
    )
}

@Suppress("DEPRECATION", "KmpDeprecationMismatch")
@Deprecated(
    "Paragraph that takes ellipsis: Boolean is deprecated, pass TextOverflow instead.",
    level = DeprecationLevel.HIDDEN,
)
actual fun Paragraph(
    paragraphIntrinsics: ParagraphIntrinsics,
    constraints: Constraints,
    maxLines: Int,
    ellipsis: Boolean,
): Paragraph {
    val i = intrinsicsOf(paragraphIntrinsics)
    return paragraph(
        i.text,
        i.style,
        i.density,
        maxLines,
        if (ellipsis) TextOverflow.Ellipsis else TextOverflow.Clip,
        constraints,
        i.annotations,
        i.placeholders,
    )
}

actual fun Paragraph(
    paragraphIntrinsics: ParagraphIntrinsics,
    constraints: Constraints,
    maxLines: Int,
    overflow: TextOverflow,
): Paragraph {
    val i = intrinsicsOf(paragraphIntrinsics)
    return paragraph(
        i.text,
        i.style,
        i.density,
        maxLines,
        overflow,
        constraints,
        i.annotations,
        i.placeholders,
    )
}

@Suppress("DEPRECATION", "KmpDeprecationMismatch")
@Deprecated("Font.ResourceLoader is deprecated, instead use FontFamily.Resolver")
actual fun ParagraphIntrinsics(
    text: String,
    style: TextStyle,
    spanStyles: List<AnnotatedString.Range<SpanStyle>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    density: Density,
    resourceLoader: Font.ResourceLoader,
): ParagraphIntrinsics =
    KlioParagraphIntrinsics(text, style, density, spanStyles, placeholders)

@Deprecated("Use an overload that takes `annotations` instead")
actual fun ParagraphIntrinsics(
    text: String,
    style: TextStyle,
    spanStyles: List<AnnotatedString.Range<SpanStyle>>,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    density: Density,
    fontFamilyResolver: FontFamily.Resolver,
): ParagraphIntrinsics =
    KlioParagraphIntrinsics(text, style, density, spanStyles, placeholders)

actual fun ParagraphIntrinsics(
    text: String,
    style: TextStyle,
    annotations: List<AnnotatedString.Range<out AnnotatedString.Annotation>>,
    density: Density,
    fontFamilyResolver: FontFamily.Resolver,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
): ParagraphIntrinsics =
    KlioParagraphIntrinsics(text, style, density, annotations, placeholders)

actual fun ParagraphIntrinsics(
    text: String,
    style: TextStyle,
    annotations: List<AnnotatedString.Range<out AnnotatedString.Annotation>>,
    density: Density,
    fontFamilyResolver: FontFamily.Resolver,
    placeholders: List<AnnotatedString.Range<Placeholder>>,
    softWrap: Boolean,
): ParagraphIntrinsics =
    KlioParagraphIntrinsics(text, style, density, annotations, placeholders)
