fun main() {
    val a = -1234567
    val b = 89
    println("${a and b} ${a or b} ${a xor b} ${a.inv()}")
    println("${a shl 3} ${a shr 3} ${a ushr 3}")
    println("${a shl 35} ${a shr 35} ${a ushr 35}")
    println("${a shl -1} ${a shr -1} ${a ushr -1}")
    val l = -1234567890123L
    val m = 98765L
    println("${l and m} ${l or m} ${l xor m} ${l.inv()}")
    println("${l shl 5} ${l shr 5} ${l ushr 5}")
    println("${l shl 70} ${l shr 70} ${l ushr 70}")
    println("${l.toInt()} ${a.toLong()} ${l.toString().length}")
    println("${Int.MIN_VALUE ushr 1} ${Int.MIN_VALUE shr 1} ${Long.MIN_VALUE ushr 1}")
}
