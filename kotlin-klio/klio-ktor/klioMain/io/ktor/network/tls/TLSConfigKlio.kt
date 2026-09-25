/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's TLS client configuration. The JVM actual configures trust through a
// javax.net TrustManager; here the trusted certificates are PEM text, the
// operating system's roots are used unless turned off, and certificate
// checks can be switched off only through a setting whose name says so.

package io.ktor.network.tls

/**
 * TLS client configuration, built by [TLSConfigBuilder].
 */
public actual class TLSConfig(
    /** The server name sent as SNI and matched against the server's certificate. */
    public val serverName: String?,
    /** PEM certificates, besides the system's roots, a server's chain may end in. */
    public val trustedCertificates: List<String>,
    /** Whether the operating system's trusted roots are used. */
    public val useSystemTrustStore: Boolean,
    /** Whether any server certificate is accepted. */
    public val insecureAcceptAnyCertificate: Boolean,
)

public actual class TLSConfigBuilder {
    /**
     * Custom server name for TLS server name extension.
     * See also: https://en.wikipedia.org/wiki/Server_Name_Indication
     */
    public actual var serverName: String? = null

    /**
     * PEM certificates a server's chain may end in, besides the operating
     * system's trusted roots. Each entry may hold several certificates.
     */
    public val trustedCertificates: MutableList<String> = mutableListOf()

    /** Whether the operating system's trusted roots are used; on by default. */
    public var useSystemTrustStore: Boolean = true

    /**
     * Accepts any server certificate, for tests against a server whose
     * certificate cannot be trusted. The handshake still checks the server's
     * signature, but not who the certificate belongs to. Never for production.
     */
    public var insecureAcceptAnyCertificate: Boolean = false

    /**
     * Create [TLSConfig].
     */
    public actual fun build(): TLSConfig = TLSConfig(
        serverName,
        trustedCertificates.toList(),
        useSystemTrustStore,
        insecureAcceptAnyCertificate,
    )
}

public actual fun TLSConfigBuilder.takeFrom(other: TLSConfigBuilder) {
    serverName = other.serverName
    trustedCertificates += other.trustedCertificates
    useSystemTrustStore = other.useSystemTrustStore
    insecureAcceptAnyCertificate = other.insecureAcceptAnyCertificate
}

/**
 * Trusts the certificates of a PEM text as roots for this client's
 * connections.
 */
public fun TLSConfigBuilder.addTrustedCertificates(pem: String) {
    trustedCertificates += pem
}
