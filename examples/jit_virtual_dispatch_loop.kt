// A hot loop dispatching through an interface to two implementations: the
// polymorphic shape the whole-function tier DOES win on (the interpreter pays
// full virtual dispatch per call). Output must match with the JIT off
// (--opt safe) or on (default).
interface Op { fun apply(a: Int): Int }
class Inc : Op { override fun apply(a: Int): Int = a + 1 }
class Dbl : Op { override fun apply(a: Int): Int = a * 2 }

fun main() {
    val ops = listOf(Inc(), Dbl())
    var acc = 0
    var i = 0
    while (i < 200_000) {
        acc = ops[i % 2].apply(acc) % 1000003
        i += 1
    }
    println("acc=$acc")
}
