// A wrapped line may begin with `&&` or `||`; they continue the
// previous boolean expression (in an expression body and a
// statement) since neither can start a statement.
fun allEq(a: Int, b: Int, c: Int): Boolean =
    a == b
        && b == c
        && a == c

fun anyZero(x: Int, y: Int): Boolean {
    val r = x == 0
        || y == 0
    return r
}

fun main() {
    println(allEq(2, 2, 2))
    println(allEq(2, 2, 3))
    println(anyZero(0, 9))
    println(anyZero(4, 5))
}
