// The exception an object's or a file's failed initialization raises, as
// Kotlin/Native names it: the first access carries the initializer's
// failure as its cause, every later one none.

package kotlin.native.internal

public class FileFailedToInitializeException(message: String?, cause: Throwable?) : Error(message, cause)
