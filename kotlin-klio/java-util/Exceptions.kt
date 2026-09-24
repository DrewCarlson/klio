/*
 * The `java.util` exceptions Kotlin's `NoSuchElementException` and
 * `ConcurrentModificationException` are type aliases of, as on the JVM.
 */
package java.util

public open class NoSuchElementException : RuntimeException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class ConcurrentModificationException : RuntimeException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}
