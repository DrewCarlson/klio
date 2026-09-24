/*
 * The `java.lang` throwables, as the JVM declares them. Kotlin's `Error`,
 * `Exception`, `IllegalStateException` and the rest are type aliases of
 * these (kotlin-sema/Exceptions.kt), so an instance's class is the JVM's:
 * its `toString` and `::class.qualifiedName` name `java.lang`.
 */
package java.lang

public open class Error : Throwable {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}

public open class Exception : Throwable {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}

public open class RuntimeException : Exception {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}

public open class IllegalArgumentException : RuntimeException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}

public open class IllegalStateException : RuntimeException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}

public open class IndexOutOfBoundsException : RuntimeException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class ArrayIndexOutOfBoundsException : IndexOutOfBoundsException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class StringIndexOutOfBoundsException : IndexOutOfBoundsException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class NegativeArraySizeException : RuntimeException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class UnsupportedOperationException : RuntimeException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}

public open class NumberFormatException : IllegalArgumentException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class NullPointerException : RuntimeException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class ClassCastException : RuntimeException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class ArithmeticException : RuntimeException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class AssertionError : Error {
    public constructor() : super()
    public constructor(message: Any?) : super(message?.toString(), message as? Throwable)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
}

public open class OutOfMemoryError : VirtualMachineError {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class IncompatibleClassChangeError : LinkageError {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}

public open class InstantiationError : IncompatibleClassChangeError {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}
