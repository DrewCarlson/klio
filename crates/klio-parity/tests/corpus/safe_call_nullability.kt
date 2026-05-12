class B(val v: Int)
class A(val b: B?)

fun pickInt(x: Int?): String = if (x == null) "none" else "$x"

fun main() {
    val a: A? = null
    println(pickInt(a?.b?.v))
    val a2: A? = A(B(7))
    println(pickInt(a2?.b?.v))
    if (a2 != null) {
        println(pickInt(a2.b?.v))
    }
}
