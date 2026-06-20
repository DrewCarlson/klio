// Repeated calls to generic top-level stdlib functions (maxOf/minOf) in a loop.
// Their overload is resolved once per (function, argument-type) and then cached,
// so the hot loop does not re-scan/type-score every overload on each call.
fun main() {
    var acc = 0
    var lacc = 0L
    var i = 0
    while (i < 100000) {
        acc = maxOf(acc, i % 100) + minOf(i, 50)
        lacc = lacc + maxOf(i.toLong(), 7L)
        i = i + 1
    }
    println("acc=$acc lacc=$lacc")
}
