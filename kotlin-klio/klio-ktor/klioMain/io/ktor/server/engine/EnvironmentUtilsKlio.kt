// klio `actual`s for the engine's environment/property bridges (the native
// versions read the process environment and SSL config through cinterop /
// platform.posix; klio neither serves TLS nor needs the env at startup).

package io.ktor.server.engine

internal actual fun ApplicationEnvironmentBuilder.configurePlatformProperties(args: Array<String>) {}

internal actual fun getKtorEnvironmentProperties(): List<Pair<String, String>> = emptyList()

internal actual fun getEnvironmentProperty(key: String): String? = null

internal actual fun setEnvironmentProperty(key: String, value: String) {}

internal actual fun clearEnvironmentProperty(key: String) {}

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
    error("TLS is not supported by the klio server engine")
}
