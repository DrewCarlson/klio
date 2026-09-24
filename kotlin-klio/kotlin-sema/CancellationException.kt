// klio `actual` the sema pipeline uses for the cancellation exception; see
// Exceptions.kt. The non-JVM stdlib's: the functions the expect declares are
// its constructors.

package kotlin.coroutines.cancellation

import kotlin.internal.InlineOnly

public actual open class CancellationException : IllegalStateException {
    public actual constructor() : super()
    public actual constructor(message: String?) : super(message)
    public constructor(message: String?, cause: Throwable?) : super(message, cause)
    public constructor(cause: Throwable?) : super(cause)
}

@Deprecated("Provided for expect-actual matching", level = DeprecationLevel.HIDDEN)
@InlineOnly
public actual inline fun CancellationException(message: String?, cause: Throwable?): CancellationException =
    CancellationException(message, cause)

@Deprecated("Provided for expect-actual matching", level = DeprecationLevel.HIDDEN)
@InlineOnly
public actual inline fun CancellationException(cause: Throwable?): CancellationException =
    CancellationException(cause)
