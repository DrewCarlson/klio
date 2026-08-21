import kotlin.math.abs
class C {
    private val stepRange = (-3661..3661 step 1831)
    private val plainRange = (0..2)
    fun go(): String {
        fun Int.padI() = "I"
        var out = ""
        for (t in plainRange) out += abs(t).padI()
        return out
    }
    fun go2(): String {
        fun Int.padI() = "I"
        var out = ""
        for (t in stepRange) out += abs(t).padI()
        return out
    }
    fun go3(): String {
        fun Int.padI() = "I"
        var out = ""
        for (t in -3661..3661 step 1831) out += abs(t).padI()
        return out
    }
}
fun main() { println(C().go()) }
