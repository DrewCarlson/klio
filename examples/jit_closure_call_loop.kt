// A loop invoking the same closure each iteration; the closure captures and
// mutates an outer `Long` variable, accumulating across every call.
fun main() {
    var acc = 0L
    val add = { n: Int -> acc += n.toLong() }
    var i = 0
    while (i < 200000) {
        add(i)
        i = i + 1
    }
    println(acc)
}
