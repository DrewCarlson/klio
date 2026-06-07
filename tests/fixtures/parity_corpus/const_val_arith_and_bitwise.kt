// `const val` initializers may use arithmetic / bitwise-infix over
// other constants and builtin primitive companion constants
// (`Long.MAX_VALUE`). Upstream kotlinx-coroutines EventLoop:
// `private const val MAX_MS = Long.MAX_VALUE / MS_TO_NS`.
const val MS_TO_NS = 1_000_000L
const val MAX_MS = Long.MAX_VALUE / MS_TO_NS
const val MASK = 1 shl 30
const val FLAGS = (1 shl 3) or (1 shl 5)
const val LOW = Int.MIN_VALUE
const val HEX = 0xFF and 0x0F

fun main() {
    println(MS_TO_NS)
    println(MAX_MS)
    println(MASK)
    println(FLAGS)
    println(LOW)
    println(HEX)
}
