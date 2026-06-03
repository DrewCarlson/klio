// Engine binding glue — these top-level helpers are shadowed at
// install time by Rust functions in klio-ktor-client/src/lib.rs that
// dispatch through `ureq`. The default Kotlin bodies are stubs that
// only run if the host binding fails to install.

package io.ktor.client.engine

internal fun __kktor_request(
    method: String,
    url: String,
    body: String,
    headers: Array<String>,
): Array<String> = arrayOf("0", "", "", "")

internal fun __kktor_get(url: String): Array<String> =
    __kktor_request("GET", url, "", emptyArray())

internal fun __kktor_post(url: String, body: String): Array<String> =
    __kktor_request("POST", url, body, emptyArray())

internal fun __kktor_setHeader(name: String, value: String): Unit = Unit
