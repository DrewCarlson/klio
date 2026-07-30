// A bare-name assignment inside a receiver lambda writes the RECEIVER's
// property, and only when the receiver actually declares it. `apply` and `run`
// are inline extensions, so their bodies are spliced into the caller and the
// receiver lives in an ordinary register rather than a capture slot; the write
// finds it there, and a receiver without the property leaves the write to the
// enclosing scope.
class Slot {
    var value: String = "empty"
    val suffix: String = "!"
}

class Bare

var value: String = "top-level"

fun main() {
    // Written through the receiver, not the same-named top-level `var`.
    println(Slot().apply { value = "applied" }.value)
    println(Slot().apply { value = "run" + suffix }.value)

    val s = Slot()
    s.run { value = "through-run" }
    println(s.value)

    with(s) { value = "through-with" }
    println(s.value)

    // The receiver declares no `value`, so the write reaches the outer binding.
    var seen = "local"
    Bare().apply { seen = "fell-through" }
    println(seen)

    // The top-level binding was never touched by any of the above.
    println(value)
}
