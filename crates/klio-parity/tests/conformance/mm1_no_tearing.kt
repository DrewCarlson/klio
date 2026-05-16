// MM1 — whole-cell access: a 64-bit value round-trips through a
// shared field intact (single-threaded reduction of no-tearing).
//> -9223372036854775807
//> 9223372036854775807
class Box { var v: Long = 0 }
fun main() {
    val b = Box()
    b.v = Long.MIN_VALUE + 1
    println(b.v)
    b.v = Long.MAX_VALUE
    println(b.v)
}
