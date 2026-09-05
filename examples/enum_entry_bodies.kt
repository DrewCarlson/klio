// An enum entry with a body is an instance of its own anonymous subclass:
// the body's properties, `init` blocks, overrides, functions, and nested
// classes belong to that entry alone, `super` reaches the enum's members,
// and the entry keeps its name and ordinal.
enum class Op(val symbol: String) {
    ADD("+") {
        override fun apply(a: Int, b: Int) = a + b
    },
    MUL("*") {
        val neutral = 1
        override fun apply(a: Int, b: Int) = a * b
        override fun describe() = super.describe() + " (neutral $neutral)"
    },
    NEG("-") {
        var uses = 0
        init {
            uses = 10
        }
        inner class Sign {
            fun of(a: Int) = if (a < 0) "negative" else "non-negative"
        }
        override fun apply(a: Int, b: Int): Int {
            uses += 1
            return -a
        }
        fun sign(a: Int) = Sign().of(a)
    };

    abstract fun apply(a: Int, b: Int): Int
    open fun describe() = "$name $symbol"
}

enum class Shape {
    CIRCLE {
        override val sides = 0
    },
    SQUARE {
        override val sides = 4
        val diagonals = sides / 2
    };
    abstract val sides: Int
}

fun main() {
    for (op in Op.entries) println("${op.ordinal} ${op.describe()} -> ${op.apply(6, 3)}")
    println(Op.NEG.apply(6, 3))
    println(Op.valueOf("MUL").apply(4, 5))
    println(Op.NEG.sign(-1))
    println(Shape.SQUARE.sides + Shape.CIRCLE.sides)
    println(Op.MUL is Op)
    println(Op.MUL == Op.valueOf("MUL"))
    println(Shape.SQUARE.name)
}
