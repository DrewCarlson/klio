// A top-level property with no annotation states its type through its
// literal initializer, so a member call on a bare read binds statically.
private const val NANOS_PER_SECOND = 1_000_000_000
private val SCALE = 2.5
private val TAG = "klio"
private val ENABLED = true
private val SEP = ':'
private const val BIG = 9_000_000_000L

fun main() {
    println(NANOS_PER_SECOND.toLong() + BIG)
    println(SCALE.toInt())
    println(TAG.uppercase() + SEP.toString())
    println(ENABLED.toString().length)
}
