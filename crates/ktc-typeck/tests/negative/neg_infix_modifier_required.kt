class V(val x: Int) {
    fun plus(o: V): V = V(x + o.x)
}

fun main() {
    val a = V(1)
    val b = V(2)
    val r = a plus b
    println(r.x)
}
