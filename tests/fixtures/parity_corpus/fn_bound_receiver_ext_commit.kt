fun <T : Iterable<String>> probe(data: T): Int = data.count { it.length == 1 }

fun main() {
    println(probe(listOf("a", "bb", "c")))
}
