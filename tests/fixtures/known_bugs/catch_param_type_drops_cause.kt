// Recording a catch parameter's declared type makes `stackTraceToString()` lose
// the `Caused by:` chain. `e.cause` is still correct — only the rendering is
// wrong, which is what makes this quiet.
//
// With the receiver typed `Throwable`, the call binds statically to
// `kotlin.stackTraceToString#5562`, the bodyless `expect` declared in
// `common/src/kotlin/ExceptionsH.kt`, and that frame is actually ENTERED:
//
//     [fn-entry] kotlin.stackTraceToString#5562: this=Exception
//
// Extension resolution admits the candidate because it carries a host symbol
// (`!has_source_body and !has_host_symbol` is what would otherwise skip it),
// but lowering then emits an ordinary interpreted Call to a function with no
// body instead of the host invocation. klio's real implementation lives in
// `host_call_member.zig` (`throwableStackMember` -> `formatThrowable`, which
// renders cause and suppressed) and never runs.
//
// Prints `true` on a tree without catch-parameter typing, `false` with it.
fun main() {
    val e = try {
        try {
            throw IllegalStateException("Root cause")
        } catch (e: Throwable) {
            throw RuntimeException("Induced", e)
        }
    } catch (e: Throwable) {
        e
    }
    println("cause-set=" + (e.cause?.message ?: "NONE"))
    println("trace-renders-cause=" + ("Root cause" in e.stackTraceToString()))
}
