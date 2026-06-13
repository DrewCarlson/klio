// klio `actual`s for the `io.ktor.util.PlatformUtils` platform-detection
// expects. klio is its own runtime; it reports as a native platform with
// development mode off (the posix actuals read these via cinterop/env).

package io.ktor.util

public actual val PlatformUtils.platform: Platform
    get() = Platform.Native

internal actual val PlatformUtils.isDevelopmentMode: Boolean
    get() = false
