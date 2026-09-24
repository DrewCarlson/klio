/*
 * The throwables klio raises that Kotlin has no common name for: an array or
 * string index out of range, a negative array size, running out of memory, a
 * class that cannot be instantiated, and a format string naming no
 * conversion. Kotlin code catches them as their supertypes too.
 */
package klio

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

/** A format string's `%` names no conversion `String.format` knows. */
public open class UnknownFormatConversionException : IllegalArgumentException {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}
