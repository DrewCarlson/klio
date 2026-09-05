// A bare call inside a class's own companion resolves among the
// constructor and the same-named top-level functions by argument type,
// exactly as it does from anywhere else: `Color(0xFFFF0000)` is a Long,
// the constructor takes a ULong, so `fun Color(color: Long)` wins and the
// packed value lands in the high 32 bits; `Color(0xFF00FF00.toInt())` picks
// the Int factory; only a ULong argument reaches the constructor.
@JvmInline
value class Color(val value: ULong) {
    val red: Float get() = ((value shr 48) and 0xffUL).toFloat() / 255.0f
    val green: Float get() = ((value shr 40) and 0xffUL).toFloat() / 255.0f
    val alpha: Float get() = ((value shr 56) and 0xffUL).toFloat() / 255.0f

    companion object {
        val Red = Color(0xFFFF0000)
        val Green = Color(0xFF00FF00.toInt())
        val Raw = Color(0x00FF000000000000UL)
        fun named(name: String): Color = if (name == "red") Color(0xFFFF0000) else Color(0)
    }
}

fun Color(color: Long): Color = Color(value = (color.toULong() and 0xffffffffUL) shl 32)
fun Color(color: Int): Color = Color(value = (color.toULong() and 0xffffffffUL) shl 32)

fun main() {
    println(Color.Red.value)
    println(Color.Red.red)
    println(Color.Red.alpha)
    println(Color.Green.green)
    println(Color.Raw.red)
    println(Color.named("red").red)
    println(Color.named("other").value)
    println(Color(0xFFFF0000).value == Color.Red.value)
}
