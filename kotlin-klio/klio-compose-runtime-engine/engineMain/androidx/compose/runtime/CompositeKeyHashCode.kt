package androidx.compose.runtime

import kotlin.text.toString as longToString

// Non-JVM platforms back CompositeKeyHashCode with a 64-bit Long. The compound
// arithmetic follows the standard implementation documented on the expects:
// compoundWith is `(this rol shift) xor segment`, its inverse unCompoundWith is
// `(this xor segment) ror shift`, and the bottom-up form is `this xor (segment
// rol shift)`.

public actual typealias CompositeKeyHashCode = Long

public actual fun CompositeKeyHashCode.toLong(): Long = this

// The bare form `this.toString(radix)` resolves to this declaration itself
// (the same-file extension outranks the default-imported kotlin.text one),
// which is infinite recursion; the alias import reaches the stdlib conversion.
public actual fun CompositeKeyHashCode.toString(radix: Int): String = this.longToString(radix)

internal actual fun CompositeKeyHashCode(initial: Int): CompositeKeyHashCode = initial.toLong()

internal actual fun CompositeKeyHashCode.compoundWith(
    segment: Int,
    shift: Int,
): CompositeKeyHashCode = this.rotateLeft(shift) xor segment.toLong()

internal actual fun CompositeKeyHashCode.unCompoundWith(
    segment: Int,
    shift: Int,
): CompositeKeyHashCode = (this xor segment.toLong()).rotateRight(shift)

internal actual fun CompositeKeyHashCode.bottomUpCompoundWith(
    segment: CompositeKeyHashCode,
    shift: Int,
): CompositeKeyHashCode = this xor segment.rotateLeft(shift)

internal actual fun CompositeKeyHashCode.bottomUpCompoundWith(
    segment: Int,
    shift: Int,
): CompositeKeyHashCode = this xor segment.toLong().rotateLeft(shift)

internal actual val CompositeKeyHashSizeBits: Int = 64

public actual val EmptyCompositeKeyHashCode: CompositeKeyHashCode = 0L
