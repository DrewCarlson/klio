package kotlinx.serialization.json.internal

internal actual object CharArrayPoolBatchSize {
    actual fun take(): CharArray = CharArray(BATCH_SIZE)
    actual fun release(array: CharArray) = Unit
}
