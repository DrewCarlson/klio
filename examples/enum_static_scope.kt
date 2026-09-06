// An enum's entries are in scope throughout the enum's body: inside its
// methods, its companion object, its nested objects, the bodies of entries
// and the lambdas an entry passes to the constructor. `entries` reads the
// same way. Entry constructor calls take named arguments, which bind
// their parameters and leave the rest to defaults.
enum class Suit(val symbol: String, val display: () -> String) {
    HEARTS("♥", { HEARTS.symbol + "h" }),
    SPADES("♠", { "s:" + SPADES.symbol }) {
        override fun describe() = "black " + symbol
    };

    open fun describe() = "red $symbol"

    fun other() = if (this == HEARTS) SPADES else HEARTS

    companion object {
        val first = HEARTS
        val all = entries.map { it.symbol }
        fun byIndex(i: Int) = entries[i]
    }

    object Rules {
        val trump = SPADES
        fun isTrump(s: Suit) = s == trump
    }
}

enum class Point(val x: Int, val y: Int, val z: Int = 0) {
    A(x = 1, y = 2),
    B(y = 3, x = 4),
    C(z = 5, y = 6, x = 7),
    D(8, 9)
}

fun main() {
    println(Suit.HEARTS.display())
    println(Suit.SPADES.display())
    println(Suit.HEARTS.describe())
    println(Suit.SPADES.describe())
    println(Suit.HEARTS.other())
    println(Suit.first)
    println(Suit.all)
    println(Suit.byIndex(1))
    println(Suit.Rules.trump)
    println(Suit.Rules.isTrump(Suit.SPADES))
    for (p in Point.entries) println("${p.name}: ${p.x} ${p.y} ${p.z}")
}
