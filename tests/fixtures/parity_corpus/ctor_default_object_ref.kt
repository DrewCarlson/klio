object Defaults {
    val tags: List<String> = listOf("a", "b", "c")
}

class Box(val items: List<String> = Defaults.tags, val label: String = "box") {
    fun describe(): String = "$label:${items.size}:${items.joinToString(",")}"
}

fun main() {
    println(Box().describe())
    println(Box(listOf("x")).describe())
    println(Box(listOf("x", "y"), "two").describe())
}
