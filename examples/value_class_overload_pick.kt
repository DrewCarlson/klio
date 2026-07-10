// Overload selection with a value-class argument: a call whose argument is a
// qualified object property of an inferred value-class type must bind the
// overload declared with that value-class parameter, never the sibling whose
// parameter is the underlying primitive — including at inline-splice sites
// forced by a non-local return in the trailing lambda.

value class Kind<T>(val mask: Int)

object Kinds {
    inline val Marked
        get() = Kind<Marked>(0b1 shl 3)
}

interface Marked

class Holder(val kindSet: Int)

internal inline fun Holder.visit(mask: Int, includeSelf: Boolean = false, block: (Holder) -> Unit) {
    println("mask-overload hit=" + (kindSet and mask != 0))
    block(this)
}

internal inline fun <reified T> Holder.visit(
    kind: Kind<T>,
    includeSelf: Boolean = false,
    includeDelegates: Boolean = false,
    block: (T) -> Unit,
) {
    println("kind-overload mask=" + kind.mask)
    visit(kind.mask, includeSelf) { }
}

fun Holder.walk(block: (Marked) -> Boolean) {
    visit(Kinds.Marked) {
        println("visited")
        if (kindSet == -1) return
    }
}

fun main() {
    Holder(1 shl 3).walk { true }
}
