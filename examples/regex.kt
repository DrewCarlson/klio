fun main() {
    val word = Regex("[A-Za-z]+")
    println(word.findAll("a quick brown fox").toList().map { it.value }.joinToString(" "))
    val kv = Regex("(\\w+)=(\\d+)")
    val text = "x=10, y=20, z=30"
    for (m in kv.findAll(text)) {
        println("${m.groupValues[1]} -> ${m.groupValues[2]}")
    }
    println("a,,b,,,c".split(Regex(",+")).joinToString("|"))
    println("hello-world-2026".replace(Regex("-"), " "))
    println(Regex.escape("a.b*c"))
    val literal = Regex.fromLiteral("1+1=2")
    println(literal.matches("1+1=2"))
}
