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

// A platform shader: its effect spec (see the Spec grammar in skia_shim.cpp),
// which the Skia shim builds the SkShader from at draw time, as skiko's
// SkShader for the same arguments.
actual class Shader internal constructor(internal val klioSpec: String)

// skiko's TransformShader: the shader under a local matrix.
internal actual class TransformShader actual constructor() {
    private var _shader: Shader? = null
    private var _wrapper: Shader? = null
    private var _matrix: String? = null

    actual fun transform(matrix: Matrix?) {
        _matrix = matrix?.let { matrix33Spec(it) }
        _wrapper = null
    }

    actual var shader: Shader?
        get() {
            val matrix = _matrix ?: return _shader
            if (_wrapper == null) {
                _wrapper = _shader?.let { Shader("local $matrix ${it.klioSpec}") }
            }
            return _wrapper
        }
        set(value) {
            _shader = value
            _wrapper = null
        }
}

/** The 3x3 part of a Compose Matrix in SkMatrix::setAll order, as skiko's Matrix33.setFrom. */
internal fun matrix33Spec(matrix: Matrix): String {
    val v = matrix.values
    return "${v[Matrix.ScaleX]} ${v[Matrix.SkewX]} ${v[Matrix.TranslateX]} " +
        "${v[Matrix.SkewY]} ${v[Matrix.ScaleY]} ${v[Matrix.TranslateY]} " +
        "${v[Matrix.Perspective0]} ${v[Matrix.Perspective1]} ${v[Matrix.Perspective2]}"
}

private fun tileModeCode(tileMode: TileMode): Int = when (tileMode) {
    TileMode.Repeated -> 1
    TileMode.Mirror -> 2
    TileMode.Decal -> 3
    else -> 0
}

/** The gradient's colors from their own channels, as skiko's Color4f, then the stops. */
private fun gradientSpec(colors: List<Color>, colorStops: List<Float>?): String {
    val sb = StringBuilder()
    sb.append(colors.size)
    for (c in colors) sb.append(' ').append(c.red).append(' ').append(c.green).append(' ').append(c.blue).append(' ').append(c.alpha)
    if (colorStops == null) {
        sb.append(" -")
    } else {
        sb.append(' ').append(colorStops.size)
        for (p in colorStops) sb.append(' ').append(p)
    }
    return sb.toString()
}

private fun validateColorStops(colors: List<Color>, colorStops: List<Float>?) {
    if (colorStops == null) {
        if (colors.size < 2) {
            throw IllegalArgumentException(
                "colors must have length of at least 2 if colorStops " +
                    "is omitted."
            )
        }
    } else if (colors.size != colorStops.size) {
        throw IllegalArgumentException(
            "colors and colorStops arguments must have" +
                " equal length."
        )
    }
}

internal actual fun ActualLinearGradientShader(
    from: Offset,
    to: Offset,
    colors: List<Color>,
    colorStops: List<Float>?,
    tileMode: TileMode,
): Shader {
    validateColorStops(colors, colorStops)
    return Shader("lin ${from.x} ${from.y} ${to.x} ${to.y} ${tileModeCode(tileMode)} ${gradientSpec(colors, colorStops)}")
}

internal actual fun ActualRadialGradientShader(
    center: Offset,
    radius: Float,
    colors: List<Color>,
    colorStops: List<Float>?,
    tileMode: TileMode,
): Shader {
    validateColorStops(colors, colorStops)
    return Shader("rad ${center.x} ${center.y} $radius ${tileModeCode(tileMode)} ${gradientSpec(colors, colorStops)}")
}

internal actual fun ActualSweepGradientShader(
    center: Offset,
    colors: List<Color>,
    colorStops: List<Float>?,
): Shader {
    validateColorStops(colors, colorStops)
    return Shader("sweep ${center.x} ${center.y} ${gradientSpec(colors, colorStops)}")
}

// The image's pixels as they are when a draw reads the shader.
internal actual fun ActualImageShader(
    image: ImageBitmap,
    tileModeX: TileMode,
    tileModeY: TileMode,
): Shader = Shader("img ${image.klioSurfaceHandle()} ${tileModeCode(tileModeX)} ${tileModeCode(tileModeY)}")

internal actual fun ActualCompositeShader(dst: Shader, src: Shader, blendMode: BlendMode): Shader =
    Shader("blend ${blendMode.skiaCode()} ${dst.klioSpec} ${src.klioSpec}")

/**
 * The platform color filter: its effect spec, from which the Skia shim builds
 * the SkColorFilter skiko makes for the same arguments.
 */
internal actual class NativeColorFilter internal constructor(internal val spec: String)

/** An ARGB color as the unsigned number a spec carries. */
private fun Int.specArgb(): Long = toLong() and 0xFFFFFFFFL

internal actual fun actualTintColorFilter(color: Color, blendMode: BlendMode): NativeColorFilter =
    NativeColorFilter("blend ${color.klioArgb().specArgb()} ${blendMode.skiaCode()}")

/** The color as packed 0xAARRGGBB, from its own channels. */
internal fun Color.klioArgb(): Int {
    val a = (alpha * 255f + 0.5f).toInt().coerceIn(0, 255)
    val r = (red * 255f + 0.5f).toInt().coerceIn(0, 255)
    val g = (green * 255f + 0.5f).toInt().coerceIn(0, 255)
    val b = (blue * 255f + 0.5f).toInt().coerceIn(0, 255)
    return (a shl 24) or (r shl 16) or (g shl 8) or b
}

/** The blend mode's index in Skia's SkBlendMode, which Compose's order follows. */
internal fun BlendMode.skiaCode(): Int = when (this) {
    BlendMode.Clear -> 0
    BlendMode.Src -> 1
    BlendMode.Dst -> 2
    BlendMode.SrcOver -> 3
    BlendMode.DstOver -> 4
    BlendMode.SrcIn -> 5
    BlendMode.DstIn -> 6
    BlendMode.SrcOut -> 7
    BlendMode.DstOut -> 8
    BlendMode.SrcAtop -> 9
    BlendMode.DstAtop -> 10
    BlendMode.Xor -> 11
    BlendMode.Plus -> 12
    BlendMode.Modulate -> 13
    BlendMode.Screen -> 14
    BlendMode.Overlay -> 15
    BlendMode.Darken -> 16
    BlendMode.Lighten -> 17
    BlendMode.ColorDodge -> 18
    BlendMode.ColorBurn -> 19
    BlendMode.Hardlight -> 20
    BlendMode.Softlight -> 21
    BlendMode.Difference -> 22
    BlendMode.Exclusion -> 23
    BlendMode.Multiply -> 24
    BlendMode.Hue -> 25
    BlendMode.Saturation -> 26
    BlendMode.Color -> 27
    BlendMode.Luminosity -> 28
    else -> 3
}

/**
 * skiko's matrix color filter: the Compose [ColorMatrix] with its offsets
 * scaled from 0..255 to 0..1, as Skia's SkColorMatrix takes them.
 */
internal actual fun actualColorMatrixColorFilter(colorMatrix: ColorMatrix): NativeColorFilter {
    val remappedValues = colorMatrix.values.copyOf()
    remappedValues[4] *= (1f / 255f)
    remappedValues[9] *= (1f / 255f)
    remappedValues[14] *= (1f / 255f)
    remappedValues[19] *= (1f / 255f)
    return NativeColorFilter("matrix " + remappedValues.joinToString(" "))
}

internal actual fun actualLightingColorFilter(multiply: Color, add: Color): NativeColorFilter =
    NativeColorFilter("light ${multiply.klioArgb().specArgb()} ${add.klioArgb().specArgb()}")

// As skiko answers (CMP-739): the identity matrix.
internal actual fun actualColorMatrixFromFilter(filter: NativeColorFilter): ColorMatrix =
    ColorMatrix()

/** A path effect: its effect spec, from which the Skia shim builds the SkPathEffect. */
internal class KlioPathEffect(internal val spec: String) : PathEffect

private fun PathEffect.klioSpec(): String {
    requirePrecondition(this is KlioPathEffect) {
        "Extracting skia path effect reference is only supported from androidx.compose.ui.graphics.SkiaBackedPathEffect instances but received ${this::class}"
    }
    return spec
}

internal actual fun actualCornerPathEffect(radius: Float): PathEffect =
    KlioPathEffect("corner $radius")

internal actual fun actualDashPathEffect(intervals: FloatArray, phase: Float): PathEffect =
    KlioPathEffect("dash $phase ${intervals.size} " + intervals.joinToString(" "))

internal actual fun actualChainPathEffect(outer: PathEffect, inner: PathEffect): PathEffect =
    KlioPathEffect("compose ${outer.klioSpec()} ${inner.klioSpec()}")

internal actual fun actualStampedPathEffect(
    shape: Path,
    advance: Float,
    phase: Float,
    style: StampedPathEffectStyle,
): PathEffect {
    val text = (shape as? KlioPath)?.serialize() ?: ""
    val code = when (style) {
        StampedPathEffectStyle.Rotate -> 1
        StampedPathEffectStyle.Morph -> 2
        else -> 0
    }
    return KlioPathEffect("path1d $advance $phase $code ${text.length} $text")
}

// An ImageBitmap is an offscreen Skia surface (KlioImageBitmap); headless it
// carries a 0 handle and stays a functional no-op.
internal actual fun ActualImageBitmap(
    width: Int,
    height: Int,
    config: ImageBitmapConfig,
    hasAlpha: Boolean,
    colorSpace: ColorSpace,
): ImageBitmap = KlioImageBitmap(width, height, config, hasAlpha, colorSpace)

// skiko decodes with Image.makeFromEncoded; the Skia shim's codecs decode here.
internal actual fun createImageBitmap(bytes: ByteArray): ImageBitmap {
    val handle = __skia_image_decode(bytes)
    if (handle == 0L) throw IllegalArgumentException("Failed to Image::makeFromEncoded")
    return KlioImageBitmap(
        width = __skia_surf_size(handle, 0),
        height = __skia_surf_size(handle, 1),
        config = ImageBitmapConfig.Argb8888,
        hasAlpha = true,
        colorSpace = androidx.compose.ui.graphics.colorspace.ColorSpaces.Srgb,
        handle = handle,
    )
}

/** Every tile mode draws through the Skia shim, as skiko's actual answers. */
actual fun TileMode.isSupported(): Boolean = true

/** Every blend mode draws through the Skia shim, as skiko's actual answers. */
actual fun BlendMode.isSupported(): Boolean = true
