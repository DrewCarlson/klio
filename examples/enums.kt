enum class Direction {
    NORTH, EAST, SOUTH, WEST;

    fun opposite(): Direction =
        if (ordinal == 0) SOUTH
        else if (ordinal == 1) WEST
        else if (ordinal == 2) NORTH
        else EAST
}

enum class HttpStatus(val code: Int, val reason: String) {
    OK(200, "OK"),
    NOT_FOUND(404, "Not Found"),
    INTERNAL_ERROR(500, "Internal Server Error");

    fun isError(): Boolean = code >= 400
}

enum class Op {
    ADD {
        override fun apply(a: Int, b: Int): Int = a + b
    },
    SUB {
        override fun apply(a: Int, b: Int): Int = a - b
    };

    abstract fun apply(a: Int, b: Int): Int
}

fun main() {
    println("--- Direction ---")
    for (d in Direction.entries) {
        println("${d.name}@${d.ordinal}")
    }

    println("--- HttpStatus ---")
    for (s in HttpStatus.values()) {
        println("${s.name}: ${s.code} ${s.reason} error=${s.isError()}")
    }

    println("--- valueOf + compare ---")
    val ok = HttpStatus.valueOf("OK")
    println(ok)
    println(ok < HttpStatus.NOT_FOUND)

    println("--- Op overrides ---")
    for (op in Op.entries) {
        println("${op.name}(2,3)=${op.apply(2, 3)}")
    }
}
