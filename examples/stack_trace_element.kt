// A throwable's stack trace elements name the frame's function, its source
// file and line, as the JVM's java.lang.StackTraceElement does, and the JVM's
// coroutine stack-frame interface is declared for code that tests for it.
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.jvm.internal.CoroutineStackFrame

fun thrower(): Nothing = throw IllegalStateException("boom")

fun main() {
    try {
        thrower()
    } catch (e: IllegalStateException) {
        val top = e.stackTrace.first()
        println(top.methodName)
        println(top.fileName)
        println(top.lineNumber)
        println(e.stackTrace.any { it.methodName == "main" })
    }
    val plain = Continuation<Unit>(EmptyCoroutineContext) {}
    println(plain is CoroutineStackFrame)
}
