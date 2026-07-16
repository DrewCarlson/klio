// Two unrelated classes declare same-named `internal inline` members; a
// bare call inside an extension on one of them must splice THAT class's
// member, not the first-registered namesake (whose body would read fields
// the receiver does not have).
package examples.inlinepick

class Table {
    val space = Space()
    internal inline fun walk(group: Int, visit: (g: Int) -> Unit) = space.walk(group, visit)
}

class Space {
    val tag = "space"
    internal inline fun walk(parent: Int, visit: (g: Int) -> Unit) {
        var current = parent
        while (current > 0) {
            visit(current)
            current -= 1
        }
    }
}

private fun Space.firstMatch(parent: Int, a: Int, b: Int): Int {
    walk(parent) { group ->
        if (group == a) return a
        if (group == b) return b
    }
    return -1
}

fun main() {
    val t = Table()
    println(t.space.firstMatch(5, 3, 9))
    println(t.space.firstMatch(5, 9, 2))
    println(t.space.firstMatch(1, 7, 9))
}
