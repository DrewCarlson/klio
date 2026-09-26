/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// HTTPS connectors for klio's engines. The JVM API takes a java.security
// KeyStore; klio takes the certificate chain and private key as PEM text,
// the form openssl and most certificate authorities hand out.

package io.ktor.server.engine

/**
 * An HTTPS connector: the server's certificate chain (its own certificate
 * first) and its private key, both PEM. The key is a P-256 ECDSA, Ed25519
 * or RSA (2048 to 4096 bits) key, unencrypted.
 */
public interface EngineSSLConnectorConfig : EngineConnectorConfig {
    /** The PEM certificate chain, the server's certificate first. */
    public val certificateChainPem: String

    /** The PEM private key of the chain's first certificate. */
    public val privateKeyPem: String
}

/**
 * Builds an [EngineSSLConnectorConfig]; the port defaults to 443.
 */
public class EngineSSLConnectorBuilder(
    override var certificateChainPem: String,
    override var privateKeyPem: String,
) : EngineConnectorBuilder(ConnectorType.HTTPS), EngineSSLConnectorConfig {
    override var port: Int = 443
}

/**
 * Adds an HTTPS connector serving [certificateChainPem] with [privateKeyPem].
 */
public inline fun ApplicationEngine.Configuration.sslConnector(
    certificateChainPem: String,
    privateKeyPem: String,
    builder: EngineSSLConnectorBuilder.() -> Unit = {}
) {
    connectors.add(EngineSSLConnectorBuilder(certificateChainPem, privateKeyPem).apply(builder))
}
