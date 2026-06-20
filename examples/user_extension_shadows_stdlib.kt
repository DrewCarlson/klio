// A user top-level extension function shadows an implicitly imported
// stdlib extension of the same name on the same receiver type. Kotlin
// resolves the same-file extension ahead of the default-imported one, so
// `1 to 2` must call the user's `Int.to` (not `kotlin.to`, which builds a
// Pair). A receiver type the user extension does not cover still reaches
// the stdlib form.

class Sum(val total: Int) {
    override fun toString() = "Sum($total)"
}

infix fun Int.to(other: Int): Sum = Sum(this + other)

fun main() {
    println(1 to 2)        // user Int.to -> Sum(3)
    println(10.to(5))      // explicit call, same extension -> Sum(15)
    println(1 combine 2)   // a non-colliding extension still resolves

    // A receiver the user extension does not cover keeps the stdlib `to`,
    // which builds a Pair.
    val p = "k" to 7
    println(p)
    println(p.first)
    println(p.second)
}

infix fun Int.combine(other: Int): Sum = Sum(this * other)
