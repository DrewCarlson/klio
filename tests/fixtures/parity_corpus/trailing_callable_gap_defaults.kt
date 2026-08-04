class Waiter {
    fun greet(value: Any, tag: Any?, handler: ((Int) -> Unit)?): String = "member3"
}
fun Waiter.greet(handler: ((Int) -> Unit)?): String = if (handler == null) "ext:null" else "ext:fn"
fun main() {
    val w = Waiter()
    val h: ((Int) -> Unit)? = { _ -> }
    println(w.greet(h))
    println(w.greet(null))
    println(w.greet("v", null) { _ -> })
}
