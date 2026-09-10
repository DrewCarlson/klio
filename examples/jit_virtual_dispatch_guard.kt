interface Op { fun apply(a: Int): Int }
class Inc : Op { override fun apply(a: Int): Int = a + 1 }
class Dbl : Op { override fun apply(a: Int): Int = a * 2 }
class Neg : Op { override fun apply(a: Int): Int = 1000003 - a }

fun main() {
    val ops = ArrayList<Op>()
    ops.add(Inc())
    ops.add(Dbl())
    var acc = 0
    var i = 0
    while (i < 400_000) {
        if (i == 200_000) ops[0] = Neg()
        acc = (ops[i % 2].apply(acc)) % 1000003
        i += 1
    }
    println("acc=" + acc)
}
