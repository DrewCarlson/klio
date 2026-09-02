package kotlinx.serialization.json.io

import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.json.Json
import kotlinx.io.Sink
import kotlinx.io.Source

public fun <T> Json.encodeToSink(serializer: SerializationStrategy<T>, value: T, sink: Sink) {
    sink.writeString(encodeToString(serializer, value))
}

public fun <T> Json.decodeFromSource(deserializer: DeserializationStrategy<T>, source: Source): T =
    decodeFromString(deserializer, source.readString())
