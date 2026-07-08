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

// A platform shader. Gradient shaders carry a serialized description ([klioText],
// "L|from|to|tile|argb,pos;…" / "R|center|radius|tile|…") the Skia shim
// reconstructs at draw time; a null/empty text is a not-yet-supported shader.
actual class Shader {
    internal var klioText: String = ""
}

internal actual class TransformShader actual constructor() {
    actual var shader: Shader? = null

    actual fun transform(matrix: Matrix?) {}
}

// A gradient colour as packed 0xAARRGGBB from the colour's own channels (avoiding
// toArgb's deferred colourspace path), matching how KlioCanvas packs paint.
private fun gradientArgb(c: Color): Int {
    val a = (c.alpha * 255f + 0.5f).toInt().coerceIn(0, 255)
    val r = (c.red * 255f + 0.5f).toInt().coerceIn(0, 255)
    val g = (c.green * 255f + 0.5f).toInt().coerceIn(0, 255)
    val b = (c.blue * 255f + 0.5f).toInt().coerceIn(0, 255)
    return (a shl 24) or (r shl 16) or (g shl 8) or b
}

private fun tileModeCode(tileMode: TileMode): Int = when (tileMode) {
    TileMode.Repeated -> 1
    TileMode.Mirror -> 2
    TileMode.Decal -> 3
    else -> 0
}

private fun stops(colors: List<Color>, colorStops: List<Float>?): String {
    val sb = StringBuilder()
    for (i in colors.indices) {
        val pos = colorStops?.getOrNull(i) ?: if (colors.size == 1) 0f else i.toFloat() / (colors.size - 1)
        // argb is unsigned; print as an unsigned Long so the shim reads all 32 bits.
        sb.append((gradientArgb(colors[i]).toLong() and 0xFFFFFFFFL).toString())
        sb.append(",")
        sb.append(pos)
        sb.append(";")
    }
    return sb.toString()
}

internal actual fun ActualLinearGradientShader(
    from: Offset,
    to: Offset,
    colors: List<Color>,
    colorStops: List<Float>?,
    tileMode: TileMode,
): Shader = Shader().apply {
    klioText = "L|${from.x},${from.y}|${to.x},${to.y}|${tileModeCode(tileMode)}|${stops(colors, colorStops)}"
}

internal actual fun ActualRadialGradientShader(
    center: Offset,
    radius: Float,
    colors: List<Color>,
    colorStops: List<Float>?,
    tileMode: TileMode,
): Shader = Shader().apply {
    klioText = "R|${center.x},${center.y}|$radius|${tileModeCode(tileMode)}|${stops(colors, colorStops)}"
}

internal actual fun ActualSweepGradientShader(
    center: Offset,
    colors: List<Color>,
    colorStops: List<Float>?,
): Shader = throw NotImplementedError("sweep gradient shaders are not yet supported")

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
