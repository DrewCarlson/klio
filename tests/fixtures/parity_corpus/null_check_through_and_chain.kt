// A `!= null` inside an `&&` chain smart-casts for the true branch, exactly as
// a bare one does, and an `== null` inside an `||` chain does the same for the
// else branch. Only a condition that WAS the whole check narrowed anything, so
// the ordinary guarded shape kept its nullable static type — and a member loses
// to a `T?` extension on a nullable receiver, which is the one case Kotlin
// reaches that extension at all. Same defect as the `is`-chain miss beside it.
open class Base {
    fun tag(): String = "member"
}

fun Base?.tag(): String = "nullable-ext"

fun bare(a: Base?): String {
    if (a != null) return a.tag()
    return "none"
}

fun trailing(a: Base?, b: Base?): String {
    if (a != null && b != null) return b.tag()
    return "none"
}

fun leading(a: Base?, b: Base?): String {
    if (a != null && b != null) return a.tag()
    return "none"
}

fun viaElse(a: Base?, b: Base?): String {
    if (a == null || b == null) return "none"
    return b.tag()
}

// Unguarded, the extension is what Kotlin picks — the control for all of it.
fun unguarded(a: Base?): String = a.tag()

fun main() {
    val x = Base()
    println(bare(x))
    println(trailing(x, x))
    println(leading(x, x))
    println(viaElse(x, x))
    println(trailing(x, null))
    println(unguarded(x))
    println(unguarded(null))
}
