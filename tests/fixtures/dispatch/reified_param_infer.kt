// Minimize: does reified `is T` work at all when T is bound via the lambda
// param annotation only (no explicit type argument)?
inline fun <reified T> classify(x: Any, block: (T) -> String): String {
    return if (x is T) "is" else "no"
}

fun main() {
    // Here T must be inferred = String from the lambda param annotation.
    println(classify("hi") { s: String -> s })   // 7? no -> "hi" is String -> is
    println(classify(7) { s: String -> s })       // 7 is String -> no
}
