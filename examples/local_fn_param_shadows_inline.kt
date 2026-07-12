// A local function-typed binding (a plain fn param like `body: () -> T`)
// shadows every top-level namesake for a bare call: the call invokes the
// value, never an inline splice of an unrelated reified/inline function.

inline fun <reified T> body(): String = "inline " + (T::class.simpleName ?: "?")

fun call(body: () -> String): String = body()

fun main() {
    println(call { "param wins" })
    println(body<Int>())
}
