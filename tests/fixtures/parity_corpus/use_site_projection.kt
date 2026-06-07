fun describe(values: List<out Any>) {
    for (v in values) {
        println(v)
    }
}

fun main() {
    describe(listOf(1, 2, 3))
    describe(listOf("a", "b"))
}
