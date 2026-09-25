// klio `actual`s for ktor-server-core's environment bridges: upstream's
// posix `EnvironmentUtilsNix.kt` and nix `EnvironmentUtils.nix.kt`, with
// `getenv`/`setenv`/`unsetenv`/`environ` going through the host instead of
// cinterop.

package io.ktor.server.engine

import io.ktor.util.__kktor_environ
import io.ktor.util.__kktor_getenv
import io.ktor.util.__kktor_setenv
import io.ktor.util.__kktor_unsetenv

internal actual fun ApplicationEnvironmentBuilder.configurePlatformProperties(args: Array<String>) {}

internal actual fun getKtorEnvironmentProperties(): List<Pair<String, String>> = buildList {
    for (keyValue in __kktor_environ()) {
        if (keyValue.startsWith("ktor.")) {
            val (key, value) = keyValue.splitPair('=') ?: continue
            add(key to value)
        }
    }
}

internal actual fun getEnvironmentProperty(key: String): String? = __kktor_getenv(key)

internal actual fun setEnvironmentProperty(key: String, value: String) {
    __kktor_setenv(key, value)
}

internal actual fun clearEnvironmentProperty(key: String) {
    __kktor_unsetenv(key)
}

internal actual fun ApplicationEngine.Configuration.configureSSLConnectors(
    host: String,
    sslPort: String,
    sslKeyStorePath: String?,
    sslKeyStorePassword: String?,
    sslPrivateKeyPassword: String?,
    sslKeyAlias: String,
    sslTrustStorePath: String?,
    sslTrustStorePassword: String?,
    sslEnabledProtocols: List<String>?
) {
    error("SSL is not supported in native")
}
