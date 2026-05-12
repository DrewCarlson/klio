class V(val x: Int) {
    infix fun plus(o: V): V = V(x + o.x)
}

infix fun Int.combine(o: Int): Int = this * 10 + o

fun main() {
    val a = V(1) plus V(2)
    println(a.x)
    val b = 3 combine 4
    println(b)
    val c = 1 combine 2 combine 3
    println(c)
}
