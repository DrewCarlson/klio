enum class Op {
    ADD {
        override fun apply(a: Int, b: Int): Int = a + b
    },
    SUB {
        override fun apply(a: Int, b: Int): Int = a - b
    },
    MUL {
        override fun apply(a: Int, b: Int): Int = a * b
    };

    abstract fun apply(a: Int, b: Int): Int

    fun describe(): String = "Op.$name"
}

fun main() {
    for (op in Op.entries) {
        println("${op.describe()} 6 3 = ${op.apply(6, 3)}")
    }
}
