package androidx.compose.foundation

// klio actual: no platform-specific indication wrapping (the desktop shape —
// Android wraps for stylus hover). The clickable node then casts the factory
// straight through.
internal actual fun platformIndication(indication: Indication?): Indication? = indication
