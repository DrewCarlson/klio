/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// `Klio`, the name klio's server engine has always had:
// `embeddedServer(Klio, port) { ... }`. It is the CIO engine, HTTP/1.1 over
// ktor-network with keep-alive, streaming bodies and WebSocket upgrade.

package io.ktor.server.engine.klio

import io.ktor.events.Events
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationEnvironment
import io.ktor.server.cio.CIO
import io.ktor.server.cio.CIOApplicationEngine
import io.ktor.server.engine.ApplicationEngineFactory

/**
 * Engine factory: `embeddedServer(Klio, port) { … }`.
 */
public object Klio : ApplicationEngineFactory<CIOApplicationEngine, CIOApplicationEngine.Configuration> {
    override fun configuration(
        configure: CIOApplicationEngine.Configuration.() -> Unit
    ): CIOApplicationEngine.Configuration = CIO.configuration(configure)

    override fun create(
        environment: ApplicationEnvironment,
        monitor: Events,
        developmentMode: Boolean,
        configuration: CIOApplicationEngine.Configuration,
        applicationProvider: () -> Application
    ): CIOApplicationEngine = CIO.create(environment, monitor, developmentMode, configuration, applicationProvider)

    override fun toString(): String = "Klio"
}
