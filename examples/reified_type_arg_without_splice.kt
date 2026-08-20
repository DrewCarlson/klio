// An explicit `<T>` at the call site binds a `reified` parameter even when the
// receiver's static type is unavailable, so the call cannot be inlined into the
// caller. Two calls that differ only in their type argument must not answer the
// same way, and a call must not inherit the argument an earlier one used.
//
// Run with: klio run examples/reified_type_arg_without_splice.kt

interface Shape
class Circle(val r: Int) : Shape
class Square(val s: Int) : Shape

class Bag(private val items: List<Any>) {
    // Read back through a member whose declared type the call site cannot see
    // without asking this class.
    fun all(): List<Any> = items
}

// An `Any`-typed hop erases the static type the call site would otherwise use.
fun erase(x: Any): Any = x

fun main() {
    val bag = Bag(listOf(Circle(1), Square(2), Circle(3), "text", 7))

    // The receiver's element type is not written anywhere at the call site.
    println("circles = " + bag.all().filterIsInstance<Circle>().map { it.r })
    println("squares = " + bag.all().filterIsInstance<Square>().map { it.s })
    println("shapes  = " + bag.all().filterIsInstance<Shape>().size)
    println("strings = " + bag.all().filterIsInstance<String>())
    println("ints    = " + bag.all().filterIsInstance<Int>())

    // Alternating type arguments at the same call shape.
    for (i in 1..2) {
        println("alt$i    = " + bag.all().filterIsInstance<Circle>().size +
            "/" + bag.all().filterIsInstance<Square>().size)
    }

    // Through an erasing hop, and with the type written out for comparison.
    @Suppress("UNCHECKED_CAST")
    val erased = erase(bag.all()) as List<Any>
    println("erased  = " + erased.filterIsInstance<Square>().map { it.s })
    val typed: List<Any> = bag.all()
    println("typed   = " + typed.filterIsInstance<Square>().map { it.s })
}
