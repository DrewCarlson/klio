// Host engine binding for the upstream client core. `__kktor_request` is
// shadowed at install time by the Rust `request` fn in
// klio-ktor-client/src/lib.rs (registered as `io.ktor.client.engine.
// __kktor_request`); the Kotlin body is a stub that only runs if the host
// binding fails to install. Gated under `client-upstream` so it doesn't
// collide with the same declaration in the legacy `shim/client` feature.

package io.ktor.client.engine

internal fun __kktor_request(
    method: String,
    url: String,
    body: String,
    headers: Array<String>,
): Array<String> = arrayOf("0", "", "", "")
