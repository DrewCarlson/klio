// A member call on a `!!`-asserted receiver resolves against the non-null
// type: inside `operator fun Int?.inc()`, `this!!.inc()` reaches the
// builtin `Int.inc` instead of re-entering the nullable extension. A
// post-increment of a nullable var through such an operator returns the
// old value.
operator fun Int?.inc(): Int = this!!.inc()
operator fun Int?.dec(): Int = this!!.dec()

fun main() {
    var i: Int? = 10
    val j = i++
    println("$j $i")
    var k: Int? = 5
    val m = --k
    println("$m $k")
    val a: Int? = 42
    println(a!!.inc())
}
