// `receiver::method` is a function VALUE bound to that receiver: it is
// invocable, it answers `is FunctionN`, and it flows anywhere a function type
// is expected — as an argument, in a collection, as a `map` transform.
// A member call on the reference resolves against the FUNCTION TYPE, so an
// extension declared on `() -> T` serves the reference itself rather than
// forwarding to the member it names.
//
// Run with: klio run examples/bound_callable_reference.kt

class Counter(private var n: Int) {
    fun current(): Int = n
    fun plus(k: Int): Int = n + k
    fun add(k: Int) { n += k }
}

fun <T> callIt(f: () -> T): T = f()
fun apply1(f: (Int) -> Int, n: Int): Int = f(n)

// Extensions on function types. `twice` and `label` compete with the members
// of whatever the reference names, and win: the receiver is the reference.
fun <T> (() -> T).twice(): List<T> = listOf(this(), this())
fun (() -> Int).label(): String = "() -> " + this()
fun <T> Iterable<T>.label(): String = "iterable"

fun main() {
    val c = Counter(42)

    val current = c::current
    println("invoke       = " + current())
    println("is Function0 = " + (current is Function0<*>))
    println("as argument  = " + callIt(current))
    println("in a list    = " + listOf(current).map { it() })

    val plus = c::plus
    println("one arg      = " + apply1(plus, 8))
    println("is Function1 = " + (plus is Function1<*, *>))
    println("as transform = " + listOf(1, 2, 3).map(plus))

    // The receiver is captured once, so later mutation shows through.
    val add = c::add
    add(10)
    println("after add    = " + current())

    // An unbound reference takes its receiver as the first parameter.
    val unbound = Counter::current
    println("unbound      = " + unbound(Counter(7)))

    // A member call on the reference binds the function-type extension, not
    // `Counter.current()` and not the same-named `Iterable` extension.
    println("ext twice    = " + current.twice())
    println("ext label    = " + current.label())
    println("ext on list  = " + listOf(1).label())
}
