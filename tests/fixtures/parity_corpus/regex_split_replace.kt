fun main() {
    val parts = "one,two,,three".split(Regex(","))
    println(parts.joinToString("|"))
    val limited = "a,b,c,d".split(Regex(","), 2)
    println(limited.joinToString("|"))
    println("foo123bar456".replace(Regex("\\d+"), "_"))
    val r = Regex("[aeiou]")
    println(r.replace("hello world", "*"))
    println(r.replaceFirst("hello world", "*"))
    val byWs = "  a   b\tc \n d ".split(Regex("\\s+"))
    println(byWs.joinToString("|"))
}
