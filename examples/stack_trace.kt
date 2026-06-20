// A thrown exception captures the call stack at the throw site. Each frame
// records the function and the source position it was executing, resolvable to
// a file and line for user, stdlib, and pack frames alike. `stackTraceToString`
// renders the captured trace; `printStackTrace` writes it to stderr.

fun innermost(): Int = throw IllegalStateException("deliberate")
fun middle(): Int = innermost()
fun outer(): Int = middle()

fun main() {
    try {
        outer()
    } catch (e: IllegalStateException) {
        val trace = e.stackTraceToString()
        // The header line is the throwable's type and message.
        val header = trace.lines().first()
        println(header.substringBefore(":"))
        println(e.message)

        // The frames, innermost first — print the function label of each,
        // independent of the absolute source path (which varies by machine).
        for (line in trace.lines()) {
            val t = line.trim()
            if (t.startsWith("at ")) {
                println(t.removePrefix("at ").substringBefore(" ("))
            }
        }

        // Every user frame carries a resolved source position (file:line).
        println("has source positions: ${trace.contains(".kt:")}")
    }
}
