fun <T> id(x: T): T = x
fun <T> first(a: T, b: T): T = a

fun main() {
    val x: Any = "hello"
    if (x is String) {
        // Smart-cast on x flows into the inference call: T resolves
        // to String, not Any, so this assigns cleanly.
        val s: String = id(x)
        println(s.length)
    }
    val y: Any? = "world"
    if (y != null && y is String) {
        val len: Int = id(y).length
        println(len)
    }
    val n: Number = 1
    if (n is Int) {
        // Both args are smart-cast to Int — first's T should resolve
        // to Int (the narrowed type), not Number.
        val r: Int = first(n, 2)
        println(r)
    }
}
