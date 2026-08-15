@JvmInline
value class ColorU(val value: ULong) {
    override fun toString(): String = "ColorU(" + (value shr 32) + ")"
}

fun main() {
    val c = ColorU(0xFF00FF00_00000000UL)
    val slots = ArrayList<Any?>()
    slots.add(c)
    slots.add(null)
    slots.add(123)
    for (s in slots) {
        val txt = if (s == null) "null" else s!!::class.simpleName + "=" + s.toString()
        println(txt)
    }
}
