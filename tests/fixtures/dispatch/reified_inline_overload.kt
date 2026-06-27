// Reified inline overload vs plain overload. The reified inline must splice and
// the no-type-arg/no-lambda plain call must not be diverted to it.
inline fun <reified T> describe(x: Any, block: (T) -> String): String {
    return if (x is T) "is:${block(x as T)}" else "no"
}

fun describe(x: Any): String = "plain:$x"

fun main() {
    println(describe(5))                                  // expect plain:5
    println(describe("hi") { s: String -> s.uppercase() }) // expect is:HI
    println(describe(7) { n: String -> n })               // 7 is not String -> no
}
