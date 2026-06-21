// A hot integer loop of bitwise infix ops (`and`/`or`/`xor`/`shl`/`shr`), which
// Kotlin lowers to member calls. The JIT emits native bitwise/shift ops with
// Int (32-bit) and Long (64-bit) count masking and sign-extension; the output
// must match with the JIT off or on, including negative operands and shift
// counts past the type width.
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
