fun main() {
    println(Regex.escape("a.b*c"))
    val r = Regex.fromLiteral("1+1")
    println(r.matches("1+1"))
    println(r.matches("11"))
    println(r.containsMatchIn("answer: 1+1 = 2"))
}
