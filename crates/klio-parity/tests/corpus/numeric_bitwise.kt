// M27 numeric fidelity: Int and Long bitwise ops at boundaries.

fun main() {
    println(1.shl(0))
    println(1.shl(1))
    println(1.shl(31))
    println(1.shl(32))   // shift count masked to 5 bits → 0
    println((-1).ushr(1))
    println((-1).shr(1))
    println(0xFF.and(0x0F))
    println(0xFF.or(0x100))
    println(0xFF.xor(0xF0))
    println(0.inv())

    println(1L.shl(0))
    println(1L.shl(63))
    println(1L.shl(64))  // shift count masked to 6 bits → 0
    println((-1L).ushr(1))
    println(0xFFL.and(0x0FL))
    println(0L.inv())
}
