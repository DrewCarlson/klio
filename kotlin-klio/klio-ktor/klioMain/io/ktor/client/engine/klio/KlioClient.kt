/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// `KlioClient`, the name klio's client engine has always had. It is the CIO
// engine: `HttpClient(KlioClient) { engine { ... } }` configures a
// `CIOEngineConfig` and creates a `CIOEngine`.

package io.ktor.client.engine.klio

import io.ktor.client.engine.HttpClientEngine
import io.ktor.client.engine.HttpClientEngineFactory
import io.ktor.client.engine.cio.CIO
import io.ktor.client.engine.cio.CIOEngineConfig

/**
 * Engine factory: `HttpClient(KlioClient) { … }`, the CIO engine.
 */
public object KlioClient : HttpClientEngineFactory<CIOEngineConfig> {
    override fun create(block: CIOEngineConfig.() -> Unit): HttpClientEngine = CIO.create(block)

    override fun toString(): String = "KlioClient"
}
