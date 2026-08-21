// An anonymous-object site is instantiated under DIFFERENT receivers, and a
// property initializer reading the enclosing receiver's member must work for
// every receiver shape: a stored field on one class, a custom getter with no
// backing field on another. The site's lowering is shared; the per-instance
// evaluation is not allowed to bake in the first receiver's storage layout.
//
// Run with: klio run examples/anonymous_object_receiver_shapes.kt

interface Sized { val count: Int }

class Stored(n: Int) : Sized { override val count = n }

class Computed(names: List<String>) : Sized {
    val items = names
    override val count: Int
        get() = items.size
}

val Sized.indices: Iterable<Int>
    get() = Iterable {
        object : Iterator<Int> {
            private var left = count
            override fun hasNext(): Boolean = left > 0
            override fun next(): Int { left -= 1; return count - left - 1 }
        }
    }

fun main() {
    // Stored first: the site is built under the backing-field receiver, and
    // the getter receiver must still initialize through the member read.
    println("stored   = " + Stored(3).indices.toList())
    println("computed = " + Computed(listOf("a", "b")).indices.toList())
    println("again    = " + Stored(1).indices.toList())

    // A meta-annotated shape of the same bug: the enum entries under each.
    val meta = listOf(Stored(2), Computed(listOf("x", "y", "z"))).map { it.indices.toList().size }
    println("mixed    = " + meta)
}
