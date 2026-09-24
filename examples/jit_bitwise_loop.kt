// Int and Long bitwise infix ops (`and`/`or`/`xor`/`shl`/`shr`) in a tight
// loop, including negative operands and shift counts past the type width:
// Int shift counts mask to 5 bits, Long shift counts mask to 6.
fun main() {
    var acc = 0
    var i = 0
    while (i < 60000) {
        val h = (i * 2654435761.toInt())
        acc = acc xor ((h shl 13) or (h shr 19)) xor (h and 0x55555555)
        acc = (acc + (i shr 1)) and 0x7fffffff
        i = i + 1
    }
    var lacc = 0L
    var j = 0
    while (j < 60000) {
        val v = j.toLong() * -1140071481932319848L
        lacc = lacc xor (v shr 7) xor (v shl 11) xor (v and 0xffffffL)
        j = j + 1
    }
    println("acc=$acc lacc=$lacc")
}
