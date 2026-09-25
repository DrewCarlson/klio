// skiko's RenderEffect actuals (SkiaBackedRenderEffect.skiko.kt), with the image
// filter described by an effect spec the Skia shim builds the SkImageFilter from.
package androidx.compose.ui.graphics

import androidx.compose.runtime.Immutable
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.geometry.Offset

/**
 * Intermediate rendering step used to render drawing commands with a corresponding
 * visual effect. A [RenderEffect] can be configured on a [GraphicsLayerScope]
 * and will be applied when drawn.
 */
@Immutable
actual sealed class RenderEffect actual constructor() {

    private var _klioImageFilter: String? = null

    /** The image filter spec (see the Spec grammar in skia_shim.cpp). */
    internal val klioImageFilter: String
        get() = _klioImageFilter ?: createImageFilter().also { _klioImageFilter = it }

    protected abstract fun createImageFilter(): String

    /**
     * Capability query to determine if the particular platform supports the [RenderEffect]. Not
     * all platforms support all render effects
     */
    actual open fun isSupported(): Boolean = true
}

/** The spec of an optional input effect. */
private fun RenderEffect?.inputSpec(): String = this?.klioImageFilter ?: "none"

private fun TileMode.specCode(): Int = when (this) {
    TileMode.Repeated -> 1
    TileMode.Mirror -> 2
    TileMode.Decal -> 3
    else -> 0
}

@Immutable
actual class BlurEffect actual constructor(
    private val renderEffect: RenderEffect?,
    private val radiusX: Float,
    private val radiusY: Float,
    private val edgeTreatment: TileMode
) : RenderEffect() {

    @OptIn(InternalComposeUiApi::class)
    override fun createImageFilter(): String =
        "blur ${convertRadiusToSigma(radiusX)} ${convertRadiusToSigma(radiusY)} " +
            "${edgeTreatment.specCode()} ${renderEffect.inputSpec()}"

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BlurEffect) return false

        if (radiusX != other.radiusX) return false
        if (radiusY != other.radiusY) return false
        if (edgeTreatment != other.edgeTreatment) return false
        if (renderEffect != other.renderEffect) return false

        return true
    }

    override fun hashCode(): Int {
        var result = renderEffect?.hashCode() ?: 0
        result = 31 * result + radiusX.hashCode()
        result = 31 * result + radiusY.hashCode()
        result = 31 * result + edgeTreatment.hashCode()
        return result
    }

    override fun toString(): String {
        return "BlurEffect(renderEffect=$renderEffect, radiusX=$radiusX, radiusY=$radiusY, " +
            "edgeTreatment=$edgeTreatment)"
    }

    companion object {

        // Constant used to convert blur radius into a corresponding sigma value
        // for the gaussian blur algorithm used within SkImageFilter.
        // This constant approximates the scaling done in the software path's
        // "high quality" mode, in SkBlurMask::Blur() (1 / sqrt(3)).
        @InternalComposeUiApi // Never supposed to be used public. Will be hidden in future versions
        val BlurSigmaScale = 0.57735f

        @InternalComposeUiApi // Never supposed to be used public. Will be hidden in future versions
        fun convertRadiusToSigma(radius: Float) =
            if (radius > 0) {
                BlurSigmaScale * radius + 0.5f
            } else {
                0.0f
            }
    }
}

@Immutable
actual class OffsetEffect actual constructor(
    private val renderEffect: RenderEffect?,
    private val offset: Offset
) : RenderEffect() {

    override fun createImageFilter(): String =
        "offset ${offset.x} ${offset.y} ${renderEffect.inputSpec()}"

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is OffsetEffect) return false

        if (renderEffect != other.renderEffect) return false
        if (offset != other.offset) return false

        return true
    }

    override fun hashCode(): Int {
        var result = renderEffect?.hashCode() ?: 0
        result = 31 * result + offset.hashCode()
        return result
    }

    override fun toString(): String {
        return "OffsetEffect(renderEffect=$renderEffect, offset=$offset)"
    }
}
