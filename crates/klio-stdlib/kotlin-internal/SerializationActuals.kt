package kotlin.internal

internal actual inline fun throwReadObjectNotSupported(): Nothing {
    throw UnsupportedOperationException("Deserialization is supported via proxy only")
}

internal actual inline fun wrapAsDeserializationException(action: () -> Unit) {
    action()
}

internal actual class ReadObjectParameterType
