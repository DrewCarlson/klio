// A member overload whose declared parameter type provably rejects the
// argument stands aside for the same-named extension: `putAll(pairs)`
// with an Array argument drops the member `putAll(Map)` and binds the
// stdlib `Array<out Pair>` extension.
fun consume(vararg pairs: Pair<Int, Int>): Map<Int, Int> {
    val m = mutableMapOf<Int, Int>()
    m += pairs
    return m
}

fun main() {
    val e = Array(5) { it }.map { it to it }
    val c = consume(*e.toTypedArray())
    println(c[3])
    println("member-arg-disproof-extension ok")
}
