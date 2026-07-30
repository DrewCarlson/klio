// Recording a catch parameter's declared type makes `stackTraceToString()` lose
// the `Caused by:` chain. `e.cause` is still correct — only the rendering is
// wrong, which is what makes this quiet.
//
// The cause is a placeholder KLIO actual in
// `kotlin-klio/kotlin-internal/ThrowableActuals.kt`:
//
//     public actual fun Throwable.stackTraceToString(): String = this.toString()
//
// It discards frames, cause and suppressed. While the receiver is untyped the
// call reaches klio's real renderer instead (`throwableStackMember` ->
// `formatThrowable` in `host_call_member.zig`); once the receiver is statically
// typed, resolution binds this actual and the host renderer never runs. The
// stub was only ever correct because nothing could resolve to it.
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
