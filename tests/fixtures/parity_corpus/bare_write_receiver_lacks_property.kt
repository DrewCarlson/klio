// The receiver only takes a bare-name write when it actually declares the
// property. Here the inline lambda's receiver has no `seen`, so the write must
// fall through to the captured outer `var` — the ownership check is what keeps
// a receiver register from swallowing writes that are not its own.
class Empty

fun main() {
    var seen: String = "none"
    Empty().apply { seen = "outer" }
    println(seen)

    var count = 0
    Empty().run { count = count + 2 }
    println(count)
}
