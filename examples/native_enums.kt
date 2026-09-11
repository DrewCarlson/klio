// `enum class` compiled to C. Each entry is one instance built before the
// program runs and rooted for its life, exactly as an `object` declaration is;
// the enum's own name is a qualifier the emitter resolves rather than a value
// it loads, so `Level.HIGH` costs nothing to reach. Every entry carries its
// own `name` and `ordinal`, which is what a comparison, a print and a `when`
// over the entries read.
enum class Level(val weight: Int, val label: String) {
    LOW(1, "low"),
    MEDIUM(5, "medium"),
    HIGH(10, "high")
}

enum class Suit {
    CLUBS, HEARTS, SPADES
}

fun severity(l: Level): String {
    return when (l) {
        Level.LOW -> "quiet"
        Level.MEDIUM -> "notice"
        else -> "alarm"
    }
}

fun total(a: Level, b: Level): Int = a.weight + b.weight

fun main() {
    println(Level.LOW.weight)
    println(Level.MEDIUM.label)
    println(Level.HIGH.name)
    println(Level.HIGH.ordinal)
    println(total(Level.LOW, Level.HIGH))
    println(severity(Level.LOW))
    println(severity(Level.MEDIUM))
    println(severity(Level.HIGH))

    // An enum with no constructor still carries its name and position.
    println(Suit.CLUBS.name)
    println(Suit.SPADES.ordinal)
    println(Suit.HEARTS == Suit.HEARTS)
    println(Suit.HEARTS == Suit.SPADES)
}
