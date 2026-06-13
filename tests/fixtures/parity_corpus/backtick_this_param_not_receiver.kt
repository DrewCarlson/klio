// A user parameter literally named `this` is an ordinary parameter, not a
// dispatch receiver. Inside `fun probe(`this`: Box)` the bare call
// `show()` has no implicit receiver in scope (the function is a plain
// top-level function, not a method or extension), so kotlinc rejects it
// (`unresolved reference 'show'`).
class Box {
    fun show(): String = "shown"
}

fun probe(`this`: Box) {
    println(show())
}

fun main() {
    probe(Box())
}
