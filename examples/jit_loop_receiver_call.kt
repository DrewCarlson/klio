// Calling methods on an object held outside the loop, the ordinary shape of
// repeatedly calling a receiver's members: a mutator taking an argument, a
// no-argument mutator, and reading the final field values back afterward.
class Counter {
    var n = 0
    var hits = 0
    fun bump(k: Int) { n += k }
    fun tally() { hits = hits + 1 }
    fun value(): Int = n
}

fun main() {
    val c = Counter()
    var i = 0
    while (i < 200_000) {
        c.bump(2)
        c.tally()
        i += 1
    }
    println("n=" + c.value() + " hits=" + c.hits)
}
