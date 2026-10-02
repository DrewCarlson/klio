// A match's range and a search's start index count UTF-16 units, as Kotlin's strings
// do, over ASCII, accented and supplementary characters alike; and finding every
// match takes one pass over the input, whatever its length.

fun main() {
    val inputs = listOf("abc 123 de 45 f6", "héllo wörld 12 ñ3", "x😀y 7 😁z 88 é9")
    val digits = Regex("[0-9]+")
    for (s in inputs) {
        println(digits.findAll(s).map { "${it.value}@${it.range}" }.toList())
        println(Regex("(\\w)(\\d)").findAll(s).map { m -> "${m.range} ${m.groups[1]?.value}${m.groups[2]?.value} ${m.next()?.range}" }.toList())
        // Walking the matches by start index.
        var m = digits.find(s)
        val seen = mutableListOf<String>()
        while (m != null) {
            seen.add("${m.value}${m.range.first}")
            m = digits.find(s, m.range.last + 1)
        }
        println(seen)
        for (i in 0..s.length) {
            val f = digits.find(s, i)
            if (f != null) print("${f.range.first} ")
        }
        println()
        println("${digits.matchAt(s, s.indexOf('1').coerceAtLeast(0))?.value} ${digits.findAll(s, 3).count()} ${s.replace(digits, "#")} ${s.split(digits)}")
    }

    // 4,000 matches in a 30,000-character string with accents in it.
    val big = (0 until 4000).joinToString(" ") { "w$it é" }
    val all = Regex("w1[0-9]+").findAll(big).toList()
    println("${all.size} ${all.first().range} ${all.last().range} ${all.sumOf { it.range.first.toLong() }}")
}
