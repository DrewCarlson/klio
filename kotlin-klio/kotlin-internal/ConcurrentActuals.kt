package kotlin
@PublishedApi
internal fun __klioMonitorEnter(lock: Any): Unit = error("intrinsic kotlin.__klioMonitorEnter not installed")
@PublishedApi
internal fun __klioMonitorExit(lock: Any): Unit = error("intrinsic kotlin.__klioMonitorExit not installed")
public inline fun <R> synchronized(lock: Any, block: () -> R): R {
    __klioMonitorEnter(lock)
    try {
        return block()
    } finally {
        __klioMonitorExit(lock)
    }
}
