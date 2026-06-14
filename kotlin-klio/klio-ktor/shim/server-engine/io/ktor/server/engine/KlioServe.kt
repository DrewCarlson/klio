// The native bind+serve intrinsic the klio server engine drives. The host
// binding `io.ktor.server.engine.__kktor_serve` (src/ktor_client/ktor_client.zig)
// shadows this stub at install time: it binds 127.0.0.1:port and, per request,
// passes a flat `[method, path, body, hk1, hv1, …]` array to `dispatch` and
// writes back the returned `[status, contentType, body, hk1, hv1, …]`.

package io.ktor.server.engine

internal fun __kktor_serve(
    port: Int,
    dispatch: (Array<String>) -> Array<String>,
): Unit = error("intrinsic io.ktor.server.engine.__kktor_serve not installed")
