import kotlin.math.abs
class C {
    private val range = (-3661..3661 step 1831)
    fun go(): String {
        fun Int.pad() = toString().padStart(2, '0')
        var out = ""
        for (t in range) out += abs(t).pad()
        return out
    }
}
fun main() { println(C().go()) }
