// A trailing-lambda call binds the lambda to the LAST function-typed
// parameter, with intermediate defaulted parameters skipped — even when
// selecting among overloads. `process(5) { … }` must pick the
// `(Int, String = "x", () -> String)` overload (tag defaulted, lambda to
// `block`), not be rejected for mis-aligning the lambda onto `tag`. The
// overload whose leading arg type matches wins.

fun process(n: Int, tag: String = "x", block: () -> String): String =
    "a:$n:$tag:${block()}"

fun process(s: String, block: () -> String): String = "b:$s:${block()}"

// Member overload with a defaulted middle param + trailing lambda.
class Runner {
    fun go(n: Int, start: Int = 0, block: () -> String): String = "go($n,$start,${block()})"
}

fun main() {
    println(process(5) { "Z" })
    println(process("hi") { "W" })
    println(Runner().go(7) { "B" })
}
