// A scalar receiver reaches a bodyless intrinsic by FuncId, but a declaration
// that carries its own body is written against the boxed representation
// (`UInt.toString()` is `uintToString(data)`, and a scalar has no `data`), so
// that one must still go by name.
fun main() {
    println(1u.toString())
    println(uintArrayOf(1u, 2u).associateWith { it.toString() })
    println(255u.toUByte())
    println(7.toShort().toInt())
    println('a'.code)
    println(3.14.toInt())
    println(true.toString())
    println(9223372036854775807uL.toString())
}
