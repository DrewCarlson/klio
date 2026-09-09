// Bitwise/shift operators written as OPERATORS (not the call-shaped spelling)
// inside a function called from a hot loop. Two gaps met here: the operator
// form left its destination untyped, and the emitter's bitwise codegen was
// unreachable from it — so one `xor` made a whole arithmetic helper
// uncompilable, and its caller trampolined per iteration. Values are checked
// across negative operands and every shift count (including `ushr`, whose 32-bit
// form must clear the sign-extended high half first), and must match with the
// JIT off (--opt safe) or on.
fun mixI(a: Int, b: Int): Int {
    var x = a and b
    x = x or (a xor b)
    x = x + (a shl (b and 7))
    x = x - (a shr (b and 7))
    x = x xor (b shl 1)
    x = x + (a ushr (b and 7))
    return x
}
fun mixL(a: Long, b: Long): Long {
    var x = a and b
    x = x or (a xor b)
    x = x + (a shl ((b and 7L).toInt()))
    x = x - (a shr ((b and 7L).toInt()))
    x = x xor (a ushr ((b and 63L).toInt()))
    return x
}
fun main() {
    var hi = 0
    var hl = 0L
    var i = -50
    while (i < 50) {
        var j = -7
        while (j < 9) {
            hi = (hi * 31 + mixI(i * 1000003, j)) 
            hl = (hl * 31L + mixL(i.toLong() * 1000000007L, j.toLong()))
            j += 1
        }
        i += 1
    }
    // run hot so the tier compiles, then check the same values again
    var k = 0
    var acc = 0
    while (k < 80_000) { acc = acc + mixI(k, k and 15); k += 1 }
    println("hi=" + hi + " hl=" + hl + " acc=" + acc)
}
