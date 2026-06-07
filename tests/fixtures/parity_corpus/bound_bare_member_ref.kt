// A bare `::member` reference inside a method/lambda is bound to the implicit
// receiver (`this::member`). When it escapes the current frame and is invoked
// later (a callback passed onward), it must still dispatch against the captured
// receiver — not lose it and fail, and not be mistaken for a same-named
// top-level function.
fun later(run: (() -> Int) -> Int): Int = run { 0 }

class Box(private var v: Int) {
    fun inc(): Int {
        v += 1
        return v
    }

    // `::inc` is bare (bound to `this`), passed to `pass`, and invoked from
    // inside `pass`'s own lambda frame — a different activation than `forward`.
    fun forward(pass: (() -> Int) -> Int): Int = pass(::inc)
}

fun main() {
    val b = Box(40)
    println(b.forward { f -> f() })
    println(b.forward { f -> f() + f() })
}
