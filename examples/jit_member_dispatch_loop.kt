// A loop whose body is nothing but member calls (`bump`, `value`) on one
// object, mutating and then reading back an Int field.
class Counter {
    var n = 0
    fun bump(k: Int) { n += k }
    fun value(): Int = n
}

fun main() {
    val c = Counter()
    var i = 0
    while (i < 200_000) {
        c.bump(1)
        i += 1
    }
    println("n=" + c.value())
}
