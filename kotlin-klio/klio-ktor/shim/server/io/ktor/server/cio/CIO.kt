// Klio shim for the CIO server engine factory. klio runs a single
// blocking accept loop in the native engine, so the factory is just the
// marker `embeddedServer` selects on.

package io.ktor.server.cio

object CIO
