// An enum's `entries` compiled to C. The entries are the singletons the program
// already builds, in declaration order, so the list is assembled from them; and
// because the emitter knows what the list holds, iterating it yields registers
// it can read members off.
enum class Suit(val rank: Int) {
    CLUBS(1), DIAMONDS(2), HEARTS(3), SPADES(4);

    fun heavy(): Boolean = rank > 2
}

fun main() {
    for (s in Suit.entries) println(s.name + " " + s.rank + " " + s.heavy())
    println(Suit.entries.size)

    var total = 0
    for (s in Suit.entries) total = total + s.rank
    println(total)

    println(Suit.HEARTS.ordinal)
    println(Suit.HEARTS.rank)
}
