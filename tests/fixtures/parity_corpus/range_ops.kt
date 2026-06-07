fun main() {
    // Int range ops.
    val r = 1..5
    println(r.reversed().toList())
    println(r.toList())
    println(r.first)
    println(r.last)
    println(r.sum())
    println(r.count())
    println(3 in r)
    println(9 in r)
    println((5..1).isEmpty())
    println((1..10 step 2).toList())
    println((10 downTo 1 step 3).toList())

    // Long range elements are Long.
    println((1L..4L).toList())
    println((1L..4L).reversed().toList())

    // Char range elements are Char.
    println(('a'..'e').toList())
    println(('a'..'e').reversed().toList())

    // indices on an array is a range.
    val xs = arrayOf("a", "b", "c", "d")
    println(xs.indices.toList())
    println(xs.indices.reversed().toList())
    for (i in xs.indices.reversed()) print(xs[i])
    println()
}
