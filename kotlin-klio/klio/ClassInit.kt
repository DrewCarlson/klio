/*
 * The errors a failed initialization raises, for an object's, a companion's
 * or a file's initializer: the first use that runs the failing initializer
 * gets an `ExceptionInInitializerError` over what it threw (an `Error` it
 * throws is rethrown itself), and every later use a `NoClassDefFoundError`.
 * Kotlin has no common name for them; these are klio's.
 */
package klio

/**
 * A class's dependence on another class that changed incompatibly, or whose
 * initialization failed.
 */
public open class LinkageError : Error {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
}

/**
 * An exception thrown by a static initializer: a file's top-level property
 * initializers or an object's initialization.
 */
public open class ExceptionInInitializerError @PublishedApi internal constructor(
    message: String?,
    thrown: Throwable?
) : LinkageError(message, thrown) {
    public constructor() : this(null, null)
    public constructor(message: String?) : this(message, null)
    public constructor(thrown: Throwable?) : this(null, thrown)

    /** The exception the initializer threw. */
    public val exception: Throwable? get() = cause
}

/**
 * A class the VM cannot use: here, one whose initialization failed before.
 */
public open class NoClassDefFoundError @PublishedApi internal constructor(
    message: String?,
    cause: Throwable?
) : LinkageError(message, cause) {
    public constructor() : this(null, null)
    public constructor(message: String?) : this(message, null)
}
