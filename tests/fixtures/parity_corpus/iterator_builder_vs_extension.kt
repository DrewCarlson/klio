// A bare `iterator { lambda }` call resolves to the lazy `iterator` builder,
// not the no-arg `Iterator<T>.iterator()` extension of the same name. The
// extension cannot host the trailing lambda, so the call must fall through to
// the builder global — exactly as the sibling `sequence { }` builder does.
fun main() {
    val it = iterator<Int> { yield(1); yield(2) }
    println(it.next())
    println(it.next())

    // An explicit-receiver `iterator()` still binds the passthrough extension.
    val base = listOf(9).iterator()
    println(base.iterator().next())
}
