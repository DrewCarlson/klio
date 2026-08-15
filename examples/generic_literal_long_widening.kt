// An integer literal flowing into a shared type-variable slot beside a
// Long peer is typed Long by inference: eq(0, 0L) compares two Longs,
// on the framed call path and the leaf expression-body serve alike.
fun <T> eq(a: T, b: T): Boolean = a == b

fun mkLong(): Long = 42L

fun main() {
    println(eq(0, 0L))
    println(eq(0L, 0))
    var i = 0
    var r = true
    while (i < 200) {
        r = eq(0, 0L)
        i++
    }
    println(r)
    println(eq(42, mkLong()))
}
