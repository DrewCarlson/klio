fun main() {
    val a: UInt = 5u
    val b: UInt = 7u
    println(a + b)
    println(a * b)
    println(b - a)
    println(b / a)
    println(b % a)

    val l: ULong = 1_000_000_000_000uL
    println(l)
    println(l * 2u.toULong())

    val arr = uintArrayOf(10u, 20u, 30u)
    for (x in arr) println(x)
    println(arr.size)

    val n: Int = 42
    val u = n.toUInt()
    println(u)
    val back = u.toInt()
    println(back)

    val byte: UByte = 200.toUByte()
    val short: UShort = 65000.toUShort()
    println(byte)
    println(short)
}
