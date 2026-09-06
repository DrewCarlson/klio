// A callable reference adapts to the function type it is used as: a
// reference to a function with defaults or a vararg, taken as a function
// of fewer parameters, supplies the omitted defaults and an empty vararg
// itself. Bound (`c::member`) and unbound (`C::member`) references adapt
// the same way, and a Unit-typed use discards the result.
fun greet(name: String, punctuation: String = "!"): String = name + punctuation
fun join(vararg parts: String, separator: String = "-"): String = parts.joinToString(separator)
fun count(prefix: String, vararg rest: Int): String = "$prefix:${rest.size}"

class Counter(val base: Int) {
    fun add(n: Int, vararg more: Int) = base + n + more.sum()
    fun label(n: Int, suffix: String = "x") = "$n$suffix"
}

fun useOne(f: (String) -> String) = f("hi")
fun useNone(f: () -> String) = f()
fun useInt(f: (Int) -> Int) = f(2)
fun useIntStr(f: (Int) -> String) = f(3)
fun useBound(f: (Counter, Int) -> Int) = f(Counter(10), 4)
fun run(f: () -> Unit) { f() }

fun main() {
    println(useOne(::greet))
    println(useNone(::join))
    println(useOne(::count))
    val c = Counter(1)
    println(useInt(c::add))
    println(useIntStr(c::label))
    println(useBound(Counter::add))
    var seen = 0
    fun bump(by: Int = 5): Int { seen += by; return seen }
    run(::bump)
    println(seen)
}
