import kotlin.enums.EnumEntries

// `EnumName.entries` is typed `EnumEntries<E>` (since Kotlin 1.9), which
// extends `List<E>`. Both `is EnumEntries<*>` and `is List<*>` should match
// it; the same checks against a plain `listOf(...)` must report `false` for
// `EnumEntries`.

enum class Light { RED, YELLOW, GREEN }

fun main() {
    val e = Light.entries
    println(e is List<*>)
    println(e is EnumEntries<*>)
    println(e.size)
    println(e[0])
    println(e[1])
    println(e[2])

    // Iteration / functional ops still work — EnumEntries IS a List.
    for (l in e) {
        println(l)
    }
    val names = e.map { it.name }
    println(names)

    // A plain list is a List but not EnumEntries.
    val plain = listOf(1, 2, 3)
    println(plain is List<*>)
    println(plain is EnumEntries<*>)
}
