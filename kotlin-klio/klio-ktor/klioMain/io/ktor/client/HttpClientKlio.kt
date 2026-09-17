// klio `actual` for the engine-less `HttpClient()` constructor. Each
// platform resolves a default engine its own way (JVM: ServiceLoader;
// posix: the `engines` loader list); klio ships exactly one engine, so
// its actual binds `KlioClient` directly.

package io.ktor.client

import io.ktor.client.engine.klio.KlioClient

public actual fun HttpClient(
    block: HttpClientConfig<*>.() -> Unit
): HttpClient = HttpClient(KlioClient, block)
