package kotlinx.serialization.json.okio

import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.json.Json
import okio.BufferedSink
import okio.BufferedSource

public fun <T> Json.encodeToBufferedSink(serializer: SerializationStrategy<T>, value: T, sink: BufferedSink) {
    sink.writeUtf8(encodeToString(serializer, value))
}

public fun <T> Json.decodeFromBufferedSource(deserializer: DeserializationStrategy<T>, source: BufferedSource): T =
    decodeFromString(deserializer, source.readUtf8())
