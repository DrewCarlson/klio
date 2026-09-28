// The unsigned types' operators built from their data: constructors from
// an integer's bits, shifts, masks, inversion, arithmetic that wraps, and
// conversions back, at the types' edges.

fun ulongs() {
    val values = ulongArrayOf(0uL, 1uL, 0x8000_0000_0000_0000uL, ULong.MAX_VALUE, 0xFF00_0000_0000_00FFuL)
    for (v in values) {
        println("UL $v ${v shl 4} ${v shr 60} ${v and 0xFFuL} ${v or 1uL} ${v xor ULong.MAX_VALUE} ${v.inv()}")
        println("   ${v + 1uL} ${v - 1uL} ${v * 3uL} ${v.toLong()} ${v.toInt()} ${v.toUInt()} ${v.toUByte()} ${v.toDouble()}")
    }
    var u = 1uL
    for (i in 0 until 70) u = (u shl 1) xor i.toULong()
    println("chain $u ${u / 7uL} ${u % 7uL} ${u > 1uL} ${u.compareTo(ULong.MAX_VALUE)}")
}

fun uints() {
    val values = uintArrayOf(0u, 1u, 0x8000_0000u, UInt.MAX_VALUE, 0xFFFFu)
    for (v in values) {
        println("UI $v ${v shl 3} ${v shr 31} ${v and 0xF0u} ${v.inv()} ${v + 1u} ${v - 1u} ${v.toInt()} ${v.toLong()} ${v.toULong()} ${v.toUShort()}")
    }
    println("from int ${(-1).toUInt()} ${Int.MIN_VALUE.toUInt()} ${(-1L).toULong()} ${(-1).toULong()}")
}

fun smalls() {
    for (b in intArrayOf(0, 1, 127, 128, 255, 256, -1)) {
        val ub = b.toUByte()
        val us = b.toUShort()
        println("S $b $ub ${ub.toInt()} ${ub.inv()} ${ub and 0x0Fu} $us ${us.toInt()} ${(us + 1u)} ${ub.toUInt() shl 4}")
    }
}

fun packed() {
    // A colour packed in a ULong, as a graphics library keeps one.
    val argb = 0xFF336699L
    val color = (argb.toULong() and 0xFFFFFFFFuL) shl 32
    val red = ((color shr 48) and 0xFFuL).toInt()
    val green = ((color shr 40) and 0xFFuL).toInt()
    val blue = ((color shr 32) and 0xFFuL).toInt()
    val alpha = ((color shr 56) and 0xFFuL).toInt()
    println("packed $color $alpha $red $green $blue ${(color shr 32).toUInt()}")
}

fun main() {
    ulongs()
    uints()
    smalls()
    packed()
}
