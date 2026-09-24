/*
 * The JVM stdlib's coroutine stack-frame interface. A continuation that is a
 * frame answers its caller's frame and the stack trace element it stands for;
 * klio's continuations are not frames, so nothing here implements it.
 */
package kotlin.coroutines.jvm.internal

@SinceKotlin("1.3")
public interface CoroutineStackFrame {
    public val callerFrame: CoroutineStackFrame?

    public fun getStackTraceElement(): StackTraceElement?
}
