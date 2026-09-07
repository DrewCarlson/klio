// `i++` and `--i` on a local declared with a nullable type resolve to the
// program's `T?.inc()`/`T?.dec()` extension, since the builtin `inc` and
// `dec` members do not take a nullable receiver; the postfix form yields
// the old value.
operator fun Int?.inc(): Int? = this
operator fun Int?.dec(): Int? = (this ?: 0) - 10

fun init(): Int? = 10

fun main() {
    var i: Int? = init()
    val j = i++
    println("$i $j")
    var k: Int? = init()
    val m = ++k
    println("$k $m")
    var d: Int? = null
    --d
    println(d)
}
