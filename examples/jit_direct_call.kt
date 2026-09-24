// A method (`step`) delegating to a sibling method (`mix`) on the same
// receiver, which combines the receiver's two fields with the call argument
// through Long arithmetic and bitwise shifts, then stores the result back
// into a field. Run across a large iteration range.
class Hash(var acc: Long, var salt: Int) {
    fun mix(n: Int): Long {
        var r = acc + n
        r = r * 31 + salt
        r = r xor (r shl 13)
        r = r * 7 + n
        r = r xor (r shl 7)
        r = r * 3 + salt
        r = r xor (r shl 17)
        r = r * 11 + n
        r = r xor (r shl 5)
        r = r * 13 + salt
        return r
    }

    fun step(n: Int): Long {
        acc = mix(n)
        return acc
    }
}

fun main() {
    val h = Hash(1L, 7)
    var i = 0
    var t = 0L
    while (i < 200_000) {
        t = t xor h.step(i)
        i += 1
    }
    println("t=" + t + " acc=" + h.acc)
}
