// `x++` carries its operand's type, so a spliced lambda parameter bound
// from `action(index++, item)` is typed like the loop counter it came from.
fun main() {
    val digits = "0123abc"
    val seen = mutableListOf<Long>()
    digits.forEachIndexed { index, ch ->
        seen.add(index.toLong() + ch.code.toLong())
    }
    println(seen.size)
    println(seen[0])

    var n = 5
    val prior = n++
    println(prior.toLong().toString() + "/" + n.toLong().toString())

    val arr = intArrayOf(9, 8, 7)
    var i = 0
    val first = arr[i++]
    println(first.toLong().toString() + "/" + i.toString())
}
