/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.colorspace.ColorSpace

// The platform "framework paint". klio models Paint as a plain value object
// (KlioPaint), so this type exists only to satisfy Paint.asFrameworkPaint()'s
// return type; it is never instantiated (asFrameworkPaint throws by default).
actual class NativePaint

// An opaque handle to a platform shader. Gradient / image / composite shaders
// are not yet wired to the Skia shim, so their factories are pending; the type
// exists so Paint.shader (nullable, default null) resolves.
actual class Shader

internal actual class TransformShader actual constructor() {
    actual var shader: Shader? = null

    actual fun transform(matrix: Matrix?) {}
}

internal actual fun ActualLinearGradientShader(
    from: Offset,
    to: Offset,
    colors: List<Color>,
    colorStops: List<Float>?,
    tileMode: TileMode,
): Shader = throw NotImplementedError("gradient shaders are not yet supported")

internal actual fun ActualRadialGradientShader(
    center: Offset,
    radius: Float,
    colors: List<Color>,
    colorStops: List<Float>?,
    tileMode: TileMode,
): Shader = throw NotImplementedError("gradient shaders are not yet supported")

internal actual fun ActualSweepGradientShader(
    center: Offset,
    colors: List<Color>,
    colorStops: List<Float>?,
): Shader = throw NotImplementedError("gradient shaders are not yet supported")

internal actual fun ActualImageShader(
    image: ImageBitmap,
    tileModeX: TileMode,
    tileModeY: TileMode,
): Shader = throw NotImplementedError("image shaders are not yet supported")

internal actual fun ActualCompositeShader(dst: Shader, src: Shader, blendMode: BlendMode): Shader =
    throw NotImplementedError("composite shaders are not yet supported")

// The platform color-filter handle + its factories (pending the Skia shim).
internal actual class NativeColorFilter

internal actual fun actualTintColorFilter(color: Color, blendMode: BlendMode): NativeColorFilter =
    throw NotImplementedError("color filters are not yet supported")

internal actual fun actualColorMatrixColorFilter(colorMatrix: ColorMatrix): NativeColorFilter =
    throw NotImplementedError("color filters are not yet supported")

internal actual fun actualLightingColorFilter(multiply: Color, add: Color): NativeColorFilter =
    throw NotImplementedError("color filters are not yet supported")

internal actual fun actualColorMatrixFromFilter(filter: NativeColorFilter): ColorMatrix =
    throw NotImplementedError("color filters are not yet supported")

// Path effects (pending the Skia shim).
internal actual fun actualCornerPathEffect(radius: Float): PathEffect =
    throw NotImplementedError("path effects are not yet supported")

internal actual fun actualDashPathEffect(intervals: FloatArray, phase: Float): PathEffect =
    throw NotImplementedError("path effects are not yet supported")

internal actual fun actualChainPathEffect(outer: PathEffect, inner: PathEffect): PathEffect =
    throw NotImplementedError("path effects are not yet supported")

internal actual fun actualStampedPathEffect(
    shape: Path,
    advance: Float,
    phase: Float,
    style: StampedPathEffectStyle,
): PathEffect = throw NotImplementedError("path effects are not yet supported")

// ImageBitmap construction / decoding (pending the Skia shim's bitmap surface).
internal actual fun ActualImageBitmap(
    width: Int,
    height: Int,
    config: ImageBitmapConfig,
    hasAlpha: Boolean,
    colorSpace: ColorSpace,
): ImageBitmap = throw NotImplementedError("ImageBitmap is not yet supported")

internal actual fun createImageBitmap(bytes: ByteArray): ImageBitmap =
    throw NotImplementedError("ImageBitmap decoding is not yet supported")
