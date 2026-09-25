/*
 * Copyright 2014-2024 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's engine-less `HttpClient()` actual, shipped with the CIO engine.
// Upstream's posix actual takes the first engine in the `engines` list, which
// ktor-client-cio fills from an `@EagerInitialization` hook
// (`Loader.posix.kt`). klio initializes top-level properties on first use, as
// the JVM does, so that hook would never run; the engine module supplies the
// actual instead, and `HttpClient()` needs the `client-cio` feature exactly as
// upstream needs an engine dependency.

package io.ktor.client

import io.ktor.client.engine.cio.CIO

public actual fun HttpClient(
    block: HttpClientConfig<*>.() -> Unit
): HttpClient = HttpClient(CIO, block)
