import kotlin.math.abs

class T5 {
    private val stepRange = (-3661..3661 step 1831)
    private val plainRange = (0..2)
    private val list = listOf(0, 1, 2)

    fun inStepRange(): String {
        fun Int.pad() = toString().padStart(2, '0')
        var out = ""
        for (t in stepRange) out += abs(t / 3600).pad()
        return out
    }
    fun inPlainRange(): String {
        fun Int.pad() = toString().padStart(2, '0')
        var out = ""
        for (t in plainRange) out += abs(t).pad()
        return out
    }
    fun inList(): String {
        fun Int.pad() = toString().padStart(2, '0')
        var out = ""
        for (t in list) out += abs(t).pad()
        return out
    }
    fun inLiteralRange(): String {
        fun Int.pad() = toString().padStart(2, '0')
        var out = ""
        for (t in 0..2) out += abs(t).pad()
        return out
    }
}
fun try1(name: String, f: () -> String) {
    try { println(name + " = " + f()) } catch (e: Throwable) { println(name + " = FAIL " + e.message) }
}
fun main() {
    val t = T5()
    try1("step   ") { t.inStepRange() }
    try1("plain  ") { t.inPlainRange() }
    try1("list   ") { t.inList() }
    try1("literal") { t.inLiteralRange() }
}
