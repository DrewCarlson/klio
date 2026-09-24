// The same loop run over receivers of different classes implementing a
// shared interface (`HasV`), where the interface property sits at a
// different field index on each implementing class (`v` is field 1 on `A`
// and field 0 on `B`).
interface HasV {
    val v: Int
}

class A(val pad: Long, override val v: Int) : HasV

class B(override val v: Int) : HasV

fun total(o: HasV, n: Int): Int {
    var t = 0
    var i = 0
    while (i < n) {
        t = (t + o.v) % 1000003
        i += 1
    }
    return t
}

fun main() {
    println("a=${total(A(0L, 3), 50000)}")
    println("b=${total(B(5), 50000)}")
    println("a2=${total(A(0L, 7), 50000)}")
}
