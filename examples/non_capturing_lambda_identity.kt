// A non-capturing lambda literal is a singleton in Kotlin: every evaluation of
// the same literal yields the same instance, so `===` (and the default `equals`)
// is true across evaluations. A capturing lambda gets a fresh instance per
// evaluation, and two different literals are distinct singletons. This identity
// is what keeps `remember { mutableStateOf(x) }.apply { value = x }` idempotent
// when `x` is a defaulted `{}` argument.

fun noCapture(cb: () -> Unit = {}): Any = cb

fun capturing(n: Int): Any = { print(n) }

fun main() {
    // Same non-capturing literal (the default), two evaluations: one instance.
    val a = noCapture()
    val b = noCapture()
    println(a === b)
    println(a == b)

    // A capturing lambda is a fresh instance each evaluation.
    println(capturing(1) === capturing(1))

    // Two distinct non-capturing literals are distinct singletons.
    val p: () -> Unit = {}
    val q: () -> Unit = {}
    println((p as Any) === (q as Any))

    // The same literal referenced through a val is stable too.
    println((p as Any) === (p as Any))
}
