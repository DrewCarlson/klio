// An inline function that invokes its lambda parameter with an INDEXED
// argument — `predicate(this[index])` — binds the spliced lambda's `it` to
// the receiver's element type, exactly as the loop-variable form does.
fun main() {
    val shorts = shortArrayOf(1, 2, 3)
    println(shorts.indexOfFirst { it.toInt() > 1 })
    println(shorts.indexOfLast { it.toInt() < 3 })

    val ints = intArrayOf(4, 5, 6)
    println(ints.indexOfFirst { it.toLong() > 4L })

    val us = ushortArrayOf(1u, 2u, 3u)
    println(us.indexOfFirst { it > 1u })
    println(us.indexOfLast { it < 3u })

    val words = arrayOf("aa", "b", "ccc")
    println(words.indexOfFirst { it.length == 1 })

    println("abc".indexOfFirst { it.isLetter() })
}
