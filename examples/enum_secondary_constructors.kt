// An enum class may declare secondary constructors after its entries. Each
// entry's arguments pick the constructor by shape, as a class instantiation
// would, and the chosen constructor delegates with `this(...)` so every entry
// ends up with the primary constructor's properties.
enum class Level(val code: Int, val label: String) {
    LOW(1, "low"),
    MID(2),
    HIGH,
    CUSTOM(9, "custom");

    constructor(code: Int) : this(code, "level-$code")
    constructor() : this(3, "high")

    override fun toString() = "$name($code, $label)"
}

enum class Tag {
    A, B(2);

    val weight: Int

    constructor() {
        weight = 1
    }

    constructor(w: Int) {
        weight = w
    }
}

fun main() {
    for (l in Level.entries) println(l)
    println(Level.valueOf("MID").label)
    println(Tag.A.weight + Tag.B.weight)
    println(Tag.B.ordinal)
}
