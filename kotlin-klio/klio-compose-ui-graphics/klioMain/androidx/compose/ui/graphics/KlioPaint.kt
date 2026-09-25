/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

/**
 * The klio [Paint] actual, skiko's SkiaBackedPaint over the state of a skia
 * paint. As there, the color and the alpha share the skia paint's packed ARGB
 * color, so alpha reads back quantized to 8 bits; the stroke join and miter
 * limit report Compose's defaults (Round, 0) while the skia paint draws with
 * its own (Miter, 4) until they are set; and the canvas's alpha multiplier is
 * folded into the color at each draw.
 */
internal class KlioPaint : Paint {
    /** The skia paint's color, 0xAARRGGBB in sRGB. */
    internal var skiaColor: Int = 0xFF000000.toInt()

    /** The skia paint's stroke join and miter limit, which the canvas draws with. */
    internal var skiaStrokeJoin: StrokeJoin = StrokeJoin.Miter
    internal var skiaStrokeMiter: Float = 4f

    private var mAlphaMultiplier = 1.0f

    var alphaMultiplier: Float
        get() = mAlphaMultiplier
        set(value) {
            val multiplier = value.coerceIn(0f, 1f)
            updateAlpha(multiplier = multiplier)
            mAlphaMultiplier = multiplier
        }

    private fun updateAlpha(alpha: Float = this.alpha, multiplier: Float = this.mAlphaMultiplier) {
        skiaColor = Color(skiaColor).copy(alpha = alpha * multiplier).toArgb()
    }

    override var alpha: Float
        get() = Color(skiaColor).alpha
        set(value) {
            updateAlpha(alpha = value)
        }

    override var isAntiAlias: Boolean = true

    override var color: Color
        get() = Color(skiaColor)
        set(color) {
            skiaColor = color.toArgb()
        }

    override var blendMode: BlendMode = BlendMode.SrcOver

    override var style: PaintingStyle = PaintingStyle.Fill

    override var strokeWidth: Float = 0f

    override var strokeCap: StrokeCap = StrokeCap.Butt

    override var strokeJoin: StrokeJoin = StrokeJoin.Round
        set(value) {
            skiaStrokeJoin = value
            field = value
        }

    override var strokeMiterLimit: Float = 0f
        set(value) {
            skiaStrokeMiter = value
            field = value
        }

    override var filterQuality: FilterQuality = FilterQuality.Medium

    override var shader: Shader? = null

    override var colorFilter: ColorFilter? = null

    override var pathEffect: PathEffect? = null

    /** A shadow's blur (`Paint.setBlurFilter`), which the canvas applies to the draw. */
    var blurFilter: androidx.compose.ui.graphics.shadow.BlurFilter? = null
}

/** The klio [Paint] factory actual. */
actual fun Paint(): Paint = KlioPaint()
