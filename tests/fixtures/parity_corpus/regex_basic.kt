fun main() {
    val r = Regex("\\d+")
    println(r.containsMatchIn("abc 42 def"))
    println(r.matches("123"))
    println(r.matches("12a"))
    val m = r.find("abc 42 xyz 7")
    println(m?.value)
    println(m?.range)
    val all = r.findAll("a1 b22 c333").toList().map { it.value }
    println(all.joinToString(","))
    println(r.toString())
    println(r.pattern)
}
