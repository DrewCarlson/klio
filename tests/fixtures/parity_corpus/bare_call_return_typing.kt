// A local initialized from a BARE top-level/extension call types from the
// committed candidate's declared return: the lambda-return pick commits
// sumOf's Long variant on the implicit receiver, and a sole arity-matching
// candidate commits directly, so the next member call on the local resolves
// statically.
private fun stamp(n: Int): String = "s$n"

fun Array<IntArray>.flatCount(): Int {
    val totalLong = sumOf { it.size.toLong() }
    return totalLong.toInt()
}

fun label(): String {
    val s = stamp(4)
    return s.uppercase()
}

fun main() {
    println(arrayOf(intArrayOf(1, 2), intArrayOf(3)).flatCount())
    println(label())
}
