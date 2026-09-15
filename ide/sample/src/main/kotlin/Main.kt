package dev.klio.sample

/**
 * Doubles every element.
 *
 * Hover this name in the IDE, or ctrl-click [List.map] below, to land in the
 * materialised stdlib source klio itself runs.
 */
fun doubled(values: List<Int>): List<Int> = values.map { it * 2 }

fun summarize(values: List<Int>): String =
    buildString {
        append("count=").append(values.size)
        append(" sum=").append(values.sum())
        append(" doubled=").append(doubled(values).joinToString())
    }

fun main() {
    println(summarize(listOf(1, 2, 3)))
}
