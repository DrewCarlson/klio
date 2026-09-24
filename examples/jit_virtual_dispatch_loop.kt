// A loop dispatching through an interface (`Op`) to two implementations,
// alternating by index.
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
