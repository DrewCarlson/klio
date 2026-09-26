package androidx.compose.ui.text.font

// The native target resolves fonts with the default interceptor on every OS.
internal actual fun createPlatformResolveInterceptor(): PlatformResolveInterceptor =
    PlatformResolveInterceptor.Default
