// An `is` check inside an `&&` chain smart-casts for the true branch, exactly
// as a bare one does. Only a condition that WAS an `is` check narrowed, so a
// guard like `if (!ignoreCase && this is String && prefix is String)` narrowed
// nothing. That is the guard `CharSequence.startsWith` is written under: its
// `this.startsWith(prefix)` resolved back to the CharSequence extension
// instead of `String.startsWith` and recursed until the stack ran out, so
// `startsWith` on a CharSequence-typed String did not merely mis-dispatch — it
// could not complete at all.
open class Shape
class Circle : Shape() {
    fun describe(): String = "circle"
}

fun Shape.describe(): String = "shape-extension"

fun bare(s: Shape): String {
    if (s is Circle) return s.describe()
    return "none"
}

fun trailing(s: Shape, on: Boolean): String {
    if (on && s is Circle) return s.describe()
    return "none"
}

fun leading(s: Shape, on: Boolean): String {
    if (s is Circle && on) return s.describe()
    return "none"
}

fun both(a: Shape, b: Shape, on: Boolean): String {
    if (a is Circle && on && b is Circle) return a.describe() + "/" + b.describe()
    return "none"
}

// The stdlib shape, end to end.
fun viaCharSequence(s: CharSequence, p: CharSequence): Boolean = s.startsWith(p)

fun main() {
    println(bare(Circle()))
    println(trailing(Circle(), true))
    println(leading(Circle(), true))
    println(both(Circle(), Circle(), true))
    println(trailing(Circle(), false))
    println(bare(Shape()))

    println(viaCharSequence("abc", "ab"))
    println(viaCharSequence("abc", "bc"))
    println(viaCharSequence(StringBuilder("abc"), "ab"))
    println("abc".removePrefix("ab"))
    println("abc".removeSurrounding("a", "c"))
}
