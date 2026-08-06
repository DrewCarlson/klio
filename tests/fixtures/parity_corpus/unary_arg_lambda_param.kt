// A unary argument keeps the shape a spliced lambda parameter needs: `!p`
// is Boolean and `-n` keeps its operand's type.
fun main() {
    val flags = listOf(true, false, true)
    val inverted = mutableListOf<String>()
    flags.forEach { f -> inverted.add((!f).toString()) }
    println(inverted.joinToString(","))

    val nums = listOf(3, -4, 5)
    val negated = nums.map { n -> (-n).toLong() }
    println(negated.joinToString(","))

    val x = 7
    val neg = -x
    println(neg.toLong().toString())
    val no = !(x > 3)
    println(no.toString().length)
}
