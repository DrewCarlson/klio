class V(val x: Int) {
    infix fun plus(o: V): V = V(x + o.x)
}

infix fun Int.combine(o: Int): Int = this * 10 + o

fun main() {
    val r = V(1) plus V(2)
    println(r.x)
    val n = 3 combine 4
    println(n)
    val chain = 1 combine 2 combine 3
    println(chain)
}
