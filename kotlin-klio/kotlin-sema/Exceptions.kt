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
        val kClass = this::class
        val name = kClass.qualifiedName ?: kClass.simpleName ?: "Throwable"
        val m = message
        return if (m != null) "$name: $m" else name
    }
}

public actual open class Error : Throwable {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
    public actual constructor(message: String?, cause: Throwable?) : super(message, cause)
    public actual constructor(cause: Throwable?) : super(cause)
}

public actual open class Exception : Throwable {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
    public actual constructor(message: String?, cause: Throwable?) : super(message, cause)
    public actual constructor(cause: Throwable?) : super(cause)
}

public actual open class RuntimeException : Exception {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
    public actual constructor(message: String?, cause: Throwable?) : super(message, cause)
    public actual constructor(cause: Throwable?) : super(cause)
}

public actual open class IllegalArgumentException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
    public actual constructor(message: String?, cause: Throwable?) : super(message, cause)
    public actual constructor(cause: Throwable?) : super(cause)
}

public actual open class IllegalStateException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
    public actual constructor(message: String?, cause: Throwable?) : super(message, cause)
    public actual constructor(cause: Throwable?) : super(cause)
}

public actual open class IndexOutOfBoundsException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
}

public actual open class ConcurrentModificationException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
    public actual constructor(message: String?, cause: Throwable?) : super(message, cause)
    public actual constructor(cause: Throwable?) : super(cause)
}

public actual open class UnsupportedOperationException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
    public actual constructor(message: String?, cause: Throwable?) : super(message, cause)
    public actual constructor(cause: Throwable?) : super(cause)
}

public actual open class NumberFormatException : IllegalArgumentException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
}

public actual open class NullPointerException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
}

public actual open class ClassCastException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
}

public actual open class AssertionError : Error {
    public actual constructor() : super()
    public actual constructor(message: Any?) : super(message?.toString(), message as? Throwable)
    public actual constructor(message: String?, cause: Throwable?) : super(message, cause)
}

public actual open class NoSuchElementException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
}

public actual open class ArithmeticException : RuntimeException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
}

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
 * The frames the throw captured, innermost first, each its function's Kotlin
 * name and where it is: `pkg.Outer.f(File.kt:line)`.
 */
internal external fun Throwable.__klioStackFrames(): Array<String>

/** Writes [text] and a line break to the standard error stream. */
internal external fun __klioPrintErr(text: String)

/**
 * The throwable as `printStackTrace` renders it: its `toString`, a tab
 * before each frame, then each suppressed exception one tab deeper and each
 * cause, whose frames that end the way the enclosing throwable's end fold
 * into `... n more`. Every line ends with a line break.
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
