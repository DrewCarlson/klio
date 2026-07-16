// Embedded resources of a bundled program (`klio bundle --include`).
//
// The `__klio_bundle_*` bodies below are inert stubs; the interpreter's
// host bindings shadow them at dispatch and serve the real bytes from
// the running bundle's resource table.
package klio.bundle

internal fun __klio_bundle_readBytes(path: String): ByteArray = ByteArray(0)
internal fun __klio_bundle_readText(path: String): String = ""
internal fun __klio_bundle_exists(path: String): Boolean = false
internal fun __klio_bundle_list(): List<String> = emptyList()

/**
 * Read access to the files embedded in this program's bundle.
 *
 * Mount paths are the ones recorded at bundle time (`--include
 * <path[:mount]>`, defaulting to the path relative to the main source's
 * directory). Reading a path that was not bundled throws
 * [IllegalArgumentException]; calling [readBytes]/[readText] outside a
 * bundle throws [IllegalStateException].
 */
object Resources {
    /** The raw bytes of the resource mounted at [path]. */
    fun readBytes(path: String): ByteArray = __klio_bundle_readBytes(path)

    /** The resource at [path] decoded as UTF-8 text. */
    fun readText(path: String): String = __klio_bundle_readText(path)

    /** Whether a resource is mounted at [path]. */
    fun exists(path: String): Boolean = __klio_bundle_exists(path)

    /** Every mount path in the bundle, sorted. */
    fun list(): List<String> = __klio_bundle_list()
}
