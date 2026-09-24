/*
 * The errors the interpreter itself raises: running out of stack is a
 * `StackOverflowError`, which Kotlin code catches like any other throwable.
 */
package klio

/**
 * The broken or exhausted state of the virtual machine.
 */
public abstract class VirtualMachineError : Error {
    public constructor() : super()
    public constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}

/**
 * Thrown when recursion runs deeper than the stack allows.
 */
public open class StackOverflowError : VirtualMachineError {
    public constructor() : super()
    public constructor(message: String?) : super(message)
}
