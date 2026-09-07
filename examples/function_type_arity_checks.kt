// A function value is an instance of the `FunctionN` interface for its own
// arity only: `::fn1` is a `Function1`, not a `Function0`; a lambda with a
// receiver counts the receiver as its first parameter; a plain class that
// implements `Function<R>` is a `Function` but no `FunctionN`. A reified
// `is T` / `as T` / `as? T` with a function type checks the same way, and a
// failed cast throws `ClassCastException`.
fun fn0() {}
fun fn1(x: Any) {}
fun fn2(a: Int, b: Int) = a + b
class MyFun : Function<Any>

inline fun <reified T> isA(x: Any): Boolean = x is T
inline fun <reified T> castOrNull(x: Any): T? = x as? T

fun main() {
    val f0: Any = ::fn0
    val f1: Any = ::fn1
    val f2: Any = ::fn2
    val l0: Any = {}
    val l1: Any = { s: String -> s.length }
    val ext: String.() -> Int = { length }
    println(f0 is Function0<*>)
    println(f0 is Function1<*, *>)
    println(f1 is Function1<*, *>)
    println(f2 is Function2<*, *, *>)
    println(f2 is Function1<*, *>)
    println(l0 is Function0<*>)
    println(l1 is Function1<*, *>)
    println((ext as Any) is Function1<*, *>)
    println(MyFun() is Function<*>)
    println(MyFun() is Function0<*>)
    println(isA<Function0<*>>(f0))
    println(isA<Function1<*, *>>(f0))
    println(isA<(Int, Int) -> Int>(f2))
    println(castOrNull<Function1<*, *>>(f0) == null)
    println(castOrNull<Function0<*>>(f0) != null)
    try {
        f1 as Function0<*>
        println("no exception")
    } catch (e: ClassCastException) {
        println("ClassCastException")
    }
    println((f1 as? Function0<*>) == null)
}
