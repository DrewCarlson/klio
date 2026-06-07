// Minimal `PrimitiveDescriptorSafe` for klio.
//
// Upstream's `PrimitiveSerialDescriptor(name, kind)` (consumed from
// SerialDescriptors.kt) delegates to the internal `PrimitiveDescriptorSafe`
// in Primitives.kt. That file imports `kotlin.uuid.*` and declares an
// `expect fun initBuiltins()` whose only purpose is a duplicate-name
// sanity guard; klio has neither. This supplies a `PrimitiveDescriptorSafe`
// that builds the same shape of primitive descriptor without the guard
// table, so the consumed public factory resolves.

package kotlinx.serialization.internal

import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.SerialKind

internal class PrimitiveSerialDescriptor(
    override val serialName: String,
    override val kind: PrimitiveKind
) : SerialDescriptor {
    override val elementsCount: Int get() = 0
    override fun getElementName(index: Int): String = err()
    override fun getElementIndex(name: String): Int = err()
    override fun isElementOptional(index: Int): Boolean = err()
    override fun getElementDescriptor(index: Int): SerialDescriptor = err()
    override fun getElementAnnotations(index: Int): List<Annotation> = err()
    override fun toString(): String = "PrimitiveDescriptor($serialName)"
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PrimitiveSerialDescriptor) return false
        return serialName == other.serialName && kind == other.kind
    }
    override fun hashCode(): Int = serialName.hashCode() + 31 * kind.hashCode()
    private fun err(): Nothing =
        throw IllegalStateException("Primitive descriptor $serialName does not have elements")
}

internal fun PrimitiveDescriptorSafe(serialName: String, kind: PrimitiveKind): SerialDescriptor =
    PrimitiveSerialDescriptor(serialName, kind)
