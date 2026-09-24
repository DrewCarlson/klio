// klio `actual`s the sema pipeline uses for the exception hierarchy.
//
// The name-resolving interpreter keeps a builtin throwable in a host value
// and finds its members by name. Lowered from sema, a throwable is an
// ordinary instance of these classes, so a subclass a program declares, a
// `catch` by class and `message`/`cause` are plain Kotlin. A native that
// throws a host exception has it replaced by an instance of the class of
// the same name before Kotlin code sees it.

package kotlin

public actual open class Throwable actual constructor(
    public actual open val message: String?,
    public actual open val cause: Throwable?,
) {
    public actual constructor(message: String?) : this(message, null)
    public actual constructor(cause: Throwable?) : this(cause?.toString(), cause)
    public actual constructor() : this(null, null)

    internal val suppressedList: MutableList<Throwable> = ArrayList()

    override fun toString(): String {
        val name = this.__klioJvmClassName()
        val m = message
        return if (m != null) "$name: $m" else name
    }
}

/** The receiver's JVM class name, as `getClass().getName()` answers it. */
internal external fun Any.__klioJvmClassName(): String

public actual typealias Error = java.lang.Error
public actual typealias Exception = java.lang.Exception
public actual typealias RuntimeException = java.lang.RuntimeException
public actual typealias IllegalArgumentException = java.lang.IllegalArgumentException
public actual typealias IllegalStateException = java.lang.IllegalStateException
public actual typealias IndexOutOfBoundsException = java.lang.IndexOutOfBoundsException
public actual typealias ConcurrentModificationException = java.util.ConcurrentModificationException
public actual typealias UnsupportedOperationException = java.lang.UnsupportedOperationException
public actual typealias NumberFormatException = java.lang.NumberFormatException
public actual typealias NullPointerException = java.lang.NullPointerException
public actual typealias ClassCastException = java.lang.ClassCastException
public actual typealias AssertionError = java.lang.AssertionError
public actual typealias NoSuchElementException = java.util.NoSuchElementException
public actual typealias ArithmeticException = java.lang.ArithmeticException

@Suppress("DEPRECATION_ERROR")
public actual open class NoWhenBranchMatchedException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
    public actual constructor(message: String?, cause: Throwable?) : super(message, cause)
    public actual constructor(cause: Throwable?) : super(cause)
}

@Suppress("DEPRECATION_ERROR")
public actual class UninitializedPropertyAccessException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
    public actual constructor(message: String?, cause: Throwable?) : super(message, cause)
    public actual constructor(cause: Throwable?) : super(cause)
}

/**
 * The frames the throw captured, innermost first, each as the JVM's
 * `StackTraceElement` renders it: `Class.method(File.kt:line)`.
 */
internal external fun Throwable.__klioStackFrames(): Array<String>

/** Writes [text] and a line break to the standard error stream. */
internal external fun __klioPrintErr(text: String)

/**
 * The throwable as the JVM's `printStackTrace` renders it: its `toString`,
 * a tab before each frame, then each suppressed exception one tab deeper and
 * each cause, whose frames that end the way the enclosing throwable's end
 * fold into `... n more`. Every line ends with a line break.
 */
public actual fun Throwable.stackTraceToString(): String {
    val sb = StringBuilder()
    val seen = ArrayList<Throwable>()
    seen.add(this)
    sb.append(toString()).append('\n')
    val trace = __klioStackFrames()
    for (frame in trace) sb.append("\tat ").append(frame).append('\n')
    for (s in suppressedList) appendEnclosed(sb, s, trace, "Suppressed: ", "\t", seen)
    val c = cause
    if (c != null) appendEnclosed(sb, c, trace, "Caused by: ", "", seen)
    return sb.toString()
}

private fun appendEnclosed(
    sb: StringBuilder,
    t: Throwable,
    enclosing: Array<String>,
    caption: String,
    prefix: String,
    seen: MutableList<Throwable>
) {
    for (s in seen) {
        if (s === t) {
            sb.append(prefix).append(caption).append("[CIRCULAR REFERENCE: ").append(t.toString()).append("]\n")
            return
        }
    }
    seen.add(t)
    val trace = t.__klioStackFrames()
    var m = trace.size - 1
    var n = enclosing.size - 1
    while (m >= 0 && n >= 0 && trace[m] == enclosing[n]) {
        m--
        n--
    }
    val common = trace.size - 1 - m
    sb.append(prefix).append(caption).append(t.toString()).append('\n')
    for (i in 0..m) sb.append(prefix).append("\tat ").append(trace[i]).append('\n')
    if (common != 0) sb.append(prefix).append("\t... ").append(common).append(" more\n")
    for (s in t.suppressedList) appendEnclosed(sb, s, trace, "Suppressed: ", prefix + "\t", seen)
    val c = t.cause
    if (c != null) appendEnclosed(sb, c, trace, "Caused by: ", prefix, seen)
}

public actual fun Throwable.printStackTrace() {
    __klioPrintErr(stackTraceToString().removeSuffix("\n"))
}

public actual fun Throwable.addSuppressed(exception: Throwable) {
    if (this !== exception) suppressedList.add(exception)
}

public actual val Throwable.suppressedExceptions: List<Throwable>
    get() = suppressedList
