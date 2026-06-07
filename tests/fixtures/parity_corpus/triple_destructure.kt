fun main() {
    val triples = listOf(Triple(1, "a", true), Triple(2, "b", false))
    for (t in triples) {
        val (n, s, flag) = t
        println("$n $s $flag")
    }
}
