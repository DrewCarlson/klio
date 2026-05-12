// Delegate class is missing the `operator` modifier on `getValue`.
// Expect a T0012 warning diagnostic from the type checker.

class BadDelegate {
    fun getValue(thisRef: Any?, prop: Any?): Int = 42
}

val x: Int by BadDelegate()

fun main() {
    println(x)
}
