// A local variable and a function can share a name. Kotlin resolves a CALL
// against functions — a variable answers one only when its type carries an
// `invoke` operator — while a plain reference to the name reads the variable.
//
// The name `make` below is both a local and a builder function; `make { 7 }`
// calls the function and `make.n` reads the local. The same shape appears
// throughout kotlinx-coroutines' own tests, which routinely write
// `val flow = flowOf(...)` beside the `flow { ... }` builder.
//
// Run with: klio run examples/local_shadows_function_call.kt

class Holder(val n: Int) {
    override fun toString(): String = "Holder($n)"
}

class Callable(val n: Int) {
    // A class that DOES declare `invoke` stays invocable through a variable.
    operator fun invoke(extra: Int): Int = n + extra
}

fun produce(): Holder = Holder(1)
fun make(body: () -> Int): Holder = Holder(body())
fun makeCallable(): Callable = Callable(10)

fun main() {
    // Initialized by an ordinary call, so nothing about the initializer's
    // shape says "not callable" — only the function's return type does.
    val make = produce()
    println("call reaches the function : " + make { 7 })
    println("name reads the local      : " + make)

    // Declaration order does not change which one a call reaches.
    val early = make { 1 }
    println("before and after agree    : " + (early.n == 1))

    // A local whose type declares `invoke` still answers the call itself.
    val makeCallable = makeCallable()
    println("invoke operator wins      : " + makeCallable(5))
}
