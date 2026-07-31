// A redeclared interface member owns a virtual slot of its own —
// `MutableList.remove` redeclares `MutableCollection.remove` — while the
// implementing body arrives through a different supertype edge keyed by the
// base declaration's slot. Nothing connected the two, so a call bound through
// the redeclaring interface dispatched into the bodyless header, and its
// host-linked form rejected an interpreted receiver: `asReversed()` returns
// such a receiver, and `remove` on it failed outright.
fun main() {
    val original = mutableListOf("a", "b", "c")
    val reversed = original.asReversed()
    reversed.remove("c")
    println(original)
    println(reversed)

    // The same call through a declared MutableList type.
    val typed: MutableList<String> = original.asReversed()
    typed.remove("a")
    println(original)
}
