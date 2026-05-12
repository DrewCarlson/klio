// `compareTo` must return Int. Declaring it as `Boolean` is a signature
// mismatch. Expect a T0088 warning diagnostic.

class Card(val rank: Int) {
    operator fun compareTo(other: Card): Boolean = rank > other.rank
}

fun main() {
    println(Card(1).rank)
}
