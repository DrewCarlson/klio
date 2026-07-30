// A `var` declared LATER in the block is not in scope for an earlier bare-name
// write. The captured-var analysis records which names need a shared cell for
// the whole body but not where each is declared, so a bare write in a receiver
// lambda that merely shares a name with a later `var` wrote that local's cell
// instead of the receiver's property — and the declaration then overwrote it.
// The later write, which really does capture the local, still goes to the cell.
class Slot {
    var value: String = "empty"
    val suffix: String = "!"
}

var value: String = "top-level"

fun main() {
    println(Slot().apply { value = "applied" }.value)
    println(Slot().apply { value = "run" + suffix }.value)

    val s = Slot()
    s.run { value = "through-run" }
    println(s.value)

    with(s) { value = "through-with" }
    println(s.value)

    var value = "local"
    Slot().apply { value = "captured" }
    println(value)

    println(topLevel())
}

fun topLevel(): String = value
