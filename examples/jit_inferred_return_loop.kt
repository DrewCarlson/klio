// Functions with inferred (expression-body) return types — no `: T` annotation —
// called in hot loops. The loop JIT infers each callee's scalar return type from
// its body (parameters carry declared types, arithmetic promotes per Kotlin's
// rules), so the result can be slot-typed and the call trampolined. Covers an
// Int-inferred top-level function, an Int+Long -> Long promotion, and a
// polymorphic method with an inferred return. Output must match with the JIT off
// (default) or on (KLIO_JIT=1).
fun sq(x: Int) = x * x
fun mix(a: Int, b: Long) = a + b

open class Hitter { open fun hit(x: Int) = x + 1 }
class Plus2 : Hitter() { override fun hit(x: Int) = x + 2 }
class Plus3 : Hitter() { override fun hit(x: Int) = x + 3 }

fun main() {
    var s = 0
    var i = 0
    while (i < 60000) {
        s = (s + sq(i)) and 0x7fffffff
        i = i + 1
    }

    var ls = 0L
    var j = 0
    while (j < 60000) {
        ls = ls + mix(j, j.toLong())
        j = j + 1
    }

    val xs: List<Hitter> = listOf(Plus2(), Plus3(), Hitter())
    var t = 0
    var k = 0
    while (k < 60000) {
        t = (t + xs[k % 3].hit(k)) and 0x7fffffff
        k = k + 1
    }

    println("s=$s ls=$ls t=$t")
}
