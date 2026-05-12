fun main() {
    val xs = listOf("a", "b", "c", "d")
    println(xs.indices)
    println(xs.lastIndex)
    for ((i, v) in xs.withIndex()) {
        println("$i=$v")
    }
    val mapped = xs.mapIndexed { i, v -> "$i:$v" }
    println(mapped)
    xs.forEachIndexed { i, v -> println("idx $i -> $v") }
    val filtered = xs.filterIndexed { i, _ -> i % 2 == 0 }
    println(filtered)
    println(xs.joinToString(separator = ", ", prefix = "[", postfix = "]"))
    println(xs.joinToString(separator = "|", prefix = "<", postfix = ">", limit = 2, truncated = "..."))
    println(xs.joinToString { it.uppercase() })
}
