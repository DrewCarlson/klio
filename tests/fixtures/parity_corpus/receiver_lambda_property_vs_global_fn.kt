// Inside a receiver lambda (`StringBuilder(…).apply { … }`) a bare member
// read resolves against the enclosing `this@Outer`, not a same-named
// top-level function. Here `parameters` names both the class's `List`
// property and a top-level `fun parameters(...)`; inside `apply` the implicit
// receiver is the StringBuilder, so the read must reach `this@Headers.
// parameters` (the list) rather than the top-level function. This is ktor's
// `HeaderValueWithParameters.toString()` shape, whose file also declares a
// top-level `fun parameters(builder)`.
fun parameters(builder: () -> Unit): String {
    builder()
    return "from-top-level-fn"
}

class Headers(val content: String, val parameters: List<Pair<String, String>>) {
    override fun toString(): String = when {
        parameters.isEmpty() -> content
        else -> StringBuilder(content.length).apply {
            append(content)
            for (index in 0..parameters.lastIndex) {
                val (k, v) = parameters[index]
                append("; ")
                append(k)
                append("=")
                append(v)
            }
        }.toString()
    }
}

fun main() {
    println(Headers("text/plain", emptyList()))
    println(Headers("form-data", listOf("name" to "file", "size" to "12")))
    println(parameters { })
}
