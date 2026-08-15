// A lambda parameter named like an enclosing delegated local must shadow
// the delegate: `sortedBy`'s comparator lambda `{ a, b -> ... }` reads its
// own params, never the caller's `var a by ...` through getValue.
import kotlin.properties.Delegates

class W(val ord: Int)

fun main() {
    var a by Delegates.observable(0) { _, _, _ -> }
    var b by Delegates.observable(0) { _, _, _ -> }
    a++
    b++
    val sorted = listOf(W(3), W(1), W(2)).sortedBy { it.ord }
    println(sorted.map { it.ord })
    println("$a $b")
}
