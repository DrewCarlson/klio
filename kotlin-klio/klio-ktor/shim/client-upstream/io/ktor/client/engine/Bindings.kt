// Host engine binding for the upstream client core. `__kktor_request` is
// shadowed at install time by the native `request` fn in
// src/ktor_client/ktor_client.zig (registered as
// `io.ktor.client.engine.__kktor_request`); the Kotlin body is a stub that
// only runs if the host binding fails to install. Gated under the `client`
// feature alongside the rest of `shim/client-upstream`.

package io.ktor.client.engine

internal fun __kktor_request(
    method: String,
    url: String,
    body: String,
    headers: Array<String>,
): Array<String> = arrayOf("0", "", "", "")
