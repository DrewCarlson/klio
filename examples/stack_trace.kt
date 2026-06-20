// A thrown exception captures the call stack at the throw site. Each frame
// records the function and the source position it was executing, resolvable to
// a file and line for user, stdlib, and pack frames alike. `stackTraceToString`
// renders the captured trace (with any `Caused by:` chain); `printStackTrace`
// writes it to stderr; `stackTrace` exposes the frames as an array.

fun innermost(): Int = throw IllegalStateException("deliberate")
fun middle(): Int = innermost()
fun outer(): Int = middle()

fun loadConfig(): Int {
    try {
        throw NumberFormatException("bad int")
    } catch (e: NumberFormatException) {
        throw IllegalStateException("config failed", e)
    }
}

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

        // The same frames are available structurally.
        println("frame count: ${e.stackTrace.size}")
    }

    // A wrapped exception keeps its cause; the rendered trace reports the
    // `Caused by:` chain.
    try {
        loadConfig()
    } catch (e: IllegalStateException) {
        val trace = e.stackTraceToString()
        println("outer: ${e.message}")
        println("cause: ${e.cause?.message}")
        println("renders caused-by: ${trace.contains("Caused by:")}")
    }
}
