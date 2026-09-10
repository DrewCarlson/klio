// The same hot loop entered with receivers of different classes. The loop JIT
// caches a loop-invariant receiver's field buffer at entry and reads the field by
// its resolved index, so entry proves the receiver still has the class those
// indices were resolved against: `v` is field 1 on `A` and field 0 on `B`.
// Output must match with the JIT off (--opt safe) or on (default).
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
