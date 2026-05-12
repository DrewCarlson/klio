// `EnumName.entries` is typed `EnumEntries<E>` (since Kotlin 1.9), an
// interface that extends `List<E>`. Both `is List<*>` and `is EnumEntries<*>`
// match it; a plain `listOf(...)` is a List but not EnumEntries.

import kotlin.enums.EnumEntries

enum class Light { RED, YELLOW, GREEN }

fun main() {
    val e = Light.entries
    println(e is List<*>)
    println(e is EnumEntries<*>)
    println(e.size)
    for (l in e) {
        println(l)
    }
    println(e.map { it.name })

    val plain = listOf("a", "b")
    println(plain is List<*>)
    println(plain is EnumEntries<*>)
}
