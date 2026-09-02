package androidx.compose.ui.graphics

import androidx.compose.runtime.Immutable
import androidx.compose.ui.geometry.Offset

@Immutable
actual sealed class RenderEffect actual constructor() {
    actual open fun isSupported(): Boolean = true
}

@Immutable
actual class BlurEffect actual constructor(
    private val renderEffect: RenderEffect?,
    private val radiusX: Float,
    private val radiusY: Float,
    private val edgeTreatment: TileMode,
) : RenderEffect() {

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
}

@Immutable
actual class OffsetEffect actual constructor(
    private val renderEffect: RenderEffect?,
    private val offset: Offset,
) : RenderEffect() {

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
