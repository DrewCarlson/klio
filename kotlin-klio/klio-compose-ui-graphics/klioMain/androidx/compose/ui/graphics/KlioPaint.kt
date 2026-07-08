/*
 * Copyright 2024 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

package androidx.compose.ui.graphics

/**
 * The klio [Paint] actual: a plain value object holding the drawing parameters.
 * The draw pass reads these fields when it rasterizes a shape through the Skia
 * shim, so there is no native paint object to manage — the defaults mirror the
 * upstream ones exactly.
 */
internal class KlioPaint : Paint {
    override var alpha: Float = DefaultAlpha
    override var isAntiAlias: Boolean = true
    override var color: Color = Color.Black
    override var blendMode: BlendMode = BlendMode.SrcOver
    override var style: PaintingStyle = PaintingStyle.Fill
    override var strokeWidth: Float = 0f
    override var strokeCap: StrokeCap = StrokeCap.Butt
    override var strokeJoin: StrokeJoin = StrokeJoin.Miter
    override var strokeMiterLimit: Float = 4f
    override var filterQuality: FilterQuality = FilterQuality.Low
    override var shader: Shader? = null
    override var colorFilter: ColorFilter? = null
    override var pathEffect: PathEffect? = null
}

/** The klio [Paint] factory actual. */
actual fun Paint(): Paint = KlioPaint()
