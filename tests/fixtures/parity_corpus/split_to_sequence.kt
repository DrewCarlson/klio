fun main() {
    println("a,b,c".splitToSequence(",").toList())
    println("1-2-3-4".splitToSequence("-").map { it.toInt() }.filter { it % 2 == 0 }.toList())
    println("x;y,z".splitToSequence(";", ",").toList())
    println("aXbYc".splitToSequence("X", "Y").count())
    println("one two  three".splitToSequence(" ").filter { it.isNotEmpty() }.toList())
}
