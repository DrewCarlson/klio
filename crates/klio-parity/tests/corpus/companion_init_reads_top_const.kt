// A top-level `const val` must be available to an eager companion/object
// initializer, which runs before top-level property initializers — `const
// val` is a compile-time constant. ktor's `URLBuilder.Companion`'s eager
// `val originUrl = Url(origin)` reaches the URL parser's `port = DEFAULT_PORT`
// this way.
const val LIMIT: Int = 100

fun doubled(): Int = LIMIT * 2

class Box {
    companion object {
        val cached: Int = doubled()
        val direct: Int = LIMIT + 1
    }
}

fun main() {
    println(Box.cached)
    println(Box.direct)
    println(LIMIT)
}
