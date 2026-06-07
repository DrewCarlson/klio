class Card(val rank: Int)

operator fun Card.compareTo(other: Card): Int = rank - other.rank

fun main() {
    println(Card(2) < Card(7))
    println(Card(9) > Card(7))
    println(Card(5) <= Card(5))
    println(Card(5) >= Card(5))
    println(Card(5) < Card(5))
}
