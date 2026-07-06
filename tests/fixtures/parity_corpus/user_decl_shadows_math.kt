// A user declaration named like a kotlin.math constant must win: kotlin.math
// is not default-imported, so `E` here is only ever the enum.
enum class E { A, B }

const val PI = 3

fun main() {
    println(E.entries)
    println(E.A)
    println(PI)
    println(kotlin.math.E > 2.7)
}
