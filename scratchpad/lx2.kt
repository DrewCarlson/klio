import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
class C {
    fun go(t: Int): String {
        fun Int.padI() = "I" + this
        fun Double.padD() = "D" + this
        return abs(t).padI() + max(t, 1).padI() + min(t, 1).padI()
    }
}
fun main() { println(C().go(-5)) }
