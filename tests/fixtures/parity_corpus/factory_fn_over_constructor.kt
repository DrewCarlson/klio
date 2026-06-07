// A top-level factory function with the same name as a class wins over the
// class constructor when the constructor cannot be satisfied by the supplied
// arguments (a missing parameter has no default). ktor declares `fun
// Url(urlString: String): Url = URLBuilder(urlString).build()` beside the
// 10-param `class Url internal constructor(...)`; `Url("…")` must call the
// factory, not bind the string to the first ctor param and pad the rest.
class Point internal constructor(val x: Int, val y: Int) {
    init { require(x in -1000..1000) }
}

fun Point(label: String): Point = Point(label.length, label.length * 2)

fun main() {
    val p = Point("hello")
    println("${p.x},${p.y}")
    val q = Point(3, 4)
    println("${q.x},${q.y}")
}
