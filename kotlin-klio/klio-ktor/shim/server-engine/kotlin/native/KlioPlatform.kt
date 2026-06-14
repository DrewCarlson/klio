// Minimal `kotlin.native.Platform` for the ktor-server posix actuals klio
// consumes (`escapeHostname` reads `Platform.osFamily`). klio's native host is
// never Windows, so the family is reported as a non-Windows value and the
// hostname-escaping branch keeps the address unchanged.

package kotlin.native

public enum class OsFamily {
    UNKNOWN, MACOSX, IOS, LINUX, WINDOWS, ANDROID, WASM, TVOS, WATCHOS
}

public object Platform {
    public val osFamily: OsFamily get() = OsFamily.LINUX
}
