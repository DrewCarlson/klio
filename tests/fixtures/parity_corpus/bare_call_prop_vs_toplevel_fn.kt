fun codes(): List<Int> = listOf(1, 2, 3)

class Registry {
    companion object {
        val codes: List<Int> = codes()
        val total: Int = codes.size
    }
}

fun main() {
    println(Registry.codes)
    println(Registry.total)
}
