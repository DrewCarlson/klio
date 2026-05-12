enum class Status {
    OK, FAIL, RETRY;

    companion object {
        fun parse(s: String): Status = entries.first { it.name == s }

        fun count(): Int = entries.size

        fun isTerminal(s: Status): Boolean = s == OK || s == FAIL
    }
}

fun main() {
    println(Status.parse("OK"))
    println(Status.parse("FAIL"))
    println(Status.parse("RETRY"))
    println(Status.count())
    println(Status.isTerminal(Status.OK))
    println(Status.isTerminal(Status.RETRY))
}
