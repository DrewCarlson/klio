// A program's resources: the files `--include` (or the manifest's
// `[application] include`) names, embedded in its bundle or, under `klio
// run`, read from disk.
//
// The `__klio_bundle_*` bodies below are inert stubs; the interpreter's
// host bindings shadow them at dispatch and serve the real bytes from
// the program's resource table.
package klio.bundle

internal fun __klio_bundle_readBytes(path: String): ByteArray = ByteArray(0)
internal fun __klio_bundle_readText(path: String): String = ""
internal fun __klio_bundle_exists(path: String): Boolean = false
internal fun __klio_bundle_list(): List<String> = emptyList()

/**
 * Read access to this program's resources: the files embedded in its
 * bundle, or under `klio run` the same files read from disk.
 *
 * Mount paths are the ones `--include <path[:mount]>` gives, defaulting to
 * the path relative to the main source's directory. Reading a path no
 * include names throws [IllegalArgumentException]; calling
 * [readBytes]/[readText] when the program has no includes throws
 * [IllegalStateException].
 */
object Resources {
    /** The raw bytes of the resource mounted at [path]. */
    fun readBytes(path: String): ByteArray = __klio_bundle_readBytes(path)

    /** The resource at [path] decoded as UTF-8 text. */
    fun readText(path: String): String = __klio_bundle_readText(path)

    /** Whether a resource is mounted at [path]. */
    fun exists(path: String): Boolean = __klio_bundle_exists(path)

    /** Every mount path, sorted. */
    fun list(): List<String> = __klio_bundle_list()
}
