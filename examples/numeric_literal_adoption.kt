// An integer literal adopts the DECLARED type at its binding site: a
// constructor property typed Short stores a Short, and `arrayOf(1, 2, 3)`
// bound to `Array<Byte>` holds Bytes — so `contentEquals` against a decoded
// array agrees element-by-element, and `(v as Any)::class` names the
// declared type, not Int.
//
// Run with: klio run examples/numeric_literal_adoption.kt

class Sensor(val id: Short, val offset: Long, val samples: Array<Byte>)

fun tagOf(v: Any): String = v::class.simpleName ?: "?"

fun main() {
    val s = Sensor(7, 12, arrayOf(1, 2, 3))
    println("id      = " + tagOf(s.id))
    println("offset  = " + tagOf(s.offset))
    println("sample  = " + tagOf(s.samples[0]))

    val decodedLike: Array<Byte> = Array(3) { (it + 1).toByte() }
    println("content = " + s.samples.contentEquals(decodedLike))

    // Function parameters adopt too.
    fun f(b: Byte) = tagOf(b)
    println("param   = " + f(1))
}
