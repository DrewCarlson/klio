// Scalar bitwise infix operators on Int and Long: and/or/xor, the three
// shifts with JVM shift-count masking (a count uses its low 5 or 6 bits),
// arithmetic vs logical right shift on negatives, and the Boolean trio.
fun main() {
    val a = 0x5A5A5A5A
    val b = 0x0F0F0F0F
    println(a and b); println(a or b); println(a xor b)
    println(a shl 4); println(a shr 4); println(a ushr 4)
    println((-8) shr 1); println((-8) ushr 1)
    println(1 shl 31); println((1 shl 31) ushr 31)
    println(3 shl 33)
    val la = 0x5A5A5A5AL * 0x100
    println(la and 0xFF00L); println(la or 1L); println(la xor la)
    println(la shl 8); println(la shr 8); println((-la) ushr 60)
    println(1L shl 63); println(5L shl 65)
    println(true and false); println(true or false); println(true xor true); println(true xor false)
    val n: Int = 0x7FFFFFFF
    println(n.inv())
}
