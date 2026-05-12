fun main() {
    val ints = IntArray(3) { i -> (i + 1) * 10 }
    val it = ints.iterator()
    println(it is IntIterator)
    println(it.hasNext())
    println(it.nextInt())
    println(it.nextInt())
    println(it.nextInt())
    println(it.hasNext())

    val chars = CharArray(2) { i -> if (i == 0) 'a' else 'b' }
    val ci = chars.iterator()
    println(ci is CharIterator)
    println(ci.nextChar())
    println(ci.nextChar())

    val xs = listOf("a", "b")
    val li = xs.iterator()
    println(li.hasNext())
    println(li.next())
    println(li.next())
    println(li.hasNext())
}
