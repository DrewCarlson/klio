import kotlin.math.max

class Bounds(private val max: Float) {
    fun clampFloor(value: Float): Float = max(value, 1.0f)
}

fun main() {
    println(Bounds(99.0f).clampFloor(0.25f))
    println(Bounds(99.0f).clampFloor(2.0f))
}
