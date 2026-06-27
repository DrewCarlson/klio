// A reified type parameter that appears only in a value parameter — including
// inside a function-typed parameter `(T) -> R` — is inferred from the argument,
// so `is T` / `as T` use the right type without an explicit `<T>`. Here `T` is
// solved from the lambda's parameter annotation `{ s: String -> … }`.

inline fun <reified T> classify(x: Any, block: (T) -> String): String =
    if (x is T) "is" else "no"

// A reified inline overload alongside a plain overload: the no-lambda call binds
// the plain one; the lambda call binds the inline one and infers T from it.
inline fun <reified T> describe(x: Any, block: (T) -> String): String =
    if (x is T) "is:${block(x as T)}" else "no"

fun describe(x: Any): String = "plain:$x"

fun main() {
    println(classify("hi") { s: String -> s })   // T = String, "hi" is String -> is
    println(classify(7) { s: String -> s })       // T = String, 7 is String  -> no
    println(describe(5))                           // plain overload -> plain:5
    println(describe("hi") { s: String -> s.uppercase() }) // T=String -> is:HI
    println(describe(7) { n: String -> n })        // T=String, 7 is String -> no
    // Explicit type argument still wins over inference.
    println(classify<Int>(7) { s: String -> s })   // T = Int, 7 is Int -> is
}
