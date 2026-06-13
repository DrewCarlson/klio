// An inline function whose parameter name collides with a variable the
// caller references inside a lambda argument body. The lambda is defined
// in the caller's scope, so its free `value` must resolve to the caller's
// `value`, not the inline function's `value` parameter. A naive splice
// rebinds the parameter and the lambda body would read the wrong one,
// re-running its expression. Pins the splice's caller-scope resolution.

inline fun wrap(value: Any?, block: () -> Int): Int = block()

var calls = 0
fun compute(value: Int): Int {
    calls += 1
    return value * 10
}

fun run(value: Int): Int {
    return wrap("tag") {
        compute(value)
    }
}

fun main() {
    val r = run(4)
    println("result=$r")
    println("calls=$calls")
}
