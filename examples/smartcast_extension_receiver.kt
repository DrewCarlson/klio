// Kotlin resolves EXTENSIONS against the static type, and a smart cast narrows
// it. Lowering hands the receiver's declared type head to the extension filter,
// so inside `is String` the head must be `String`, not the declared `Any?` —
// otherwise the filter refutes every `CharSequence` extension and `isEmpty()`
// misses the member walk entirely. Covers both the `when`-subject and the
// `if (x is T)` forms.

fun render(any: Any?): String = when (any) {
    null -> "null"
    is String -> when {
        any.isEmpty() -> "empty"
        any.length < 5 -> "short:$any"
        else -> "long:${any.length}"
    }
    is Int -> if (any > 0) "pos:$any" else "nonpos:$any"
    else -> "?"
}

fun describe(v: Any): String {
    if (v is String) return "str(${v.isEmpty()},${v.isNotEmpty()})"
    if (v is List<*>) return "list(${v.isEmpty()})"
    return "other"
}

fun main() {
    val xs: List<Any?> = listOf(null, "", "hi", "kotlin world", 7, -3, 3.14)
    println(xs.joinToString(",") { render(it) })
    println(describe(""))
    println(describe("ab"))
    println(describe(listOf<Int>()))
    println(describe(1.5))
}
