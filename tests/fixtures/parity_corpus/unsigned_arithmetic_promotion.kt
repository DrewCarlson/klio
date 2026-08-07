fun spans(a: UInt, b: UInt, c: ULong, d: UByte, e: UShort): String {
    val diff = (b - 1u).toUInt()
    val wide = (c - 1uL).toULong()
    val mixedWide = (a.toULong() + c).toULong()
    val small = (d + d).toUInt()
    val shortish = (e + e).toUInt()
    val prod = (a * b).toUInt()
    val quot = (b / 2u).toUInt()
    return listOf(diff, wide, mixedWide, small, shortish, prod, quot).joinToString(",")
}

fun ranged(to: UInt): String {
    val r = 0u until to
    return "${r.first}..${r.last}"
}

fun main() {
    println(spans(3u, 10u, 100uL, 4u, 5u))
    println(ranged(4u))
    println(ranged(0u))
}
