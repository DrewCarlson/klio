package klio.semaoracle

/** One output row. `start`/`end` are UTF-8 byte offsets into the original file. */
data class Site(
    val start: Int,
    val end: Int,
    val kind: String,
    val target: String,
    val dispatch: String,
    val extension: String,
)

/**
 * Per-file sink the plugin writes into. Holds the mapping from the compiler's
 * UTF-16 offsets (over line-separator-normalized, BOM-stripped text) to byte
 * offsets into the file exactly as it sits on disk.
 */
class FileCollector(val displayPath: String, bytes: ByteArray, val debug: Boolean) {
    val sites = ArrayList<Site>()
    val debugLines = ArrayList<String>()
    var unresolved = 0
    var visited = false

    private val charToByte: IntArray

    init {
        var i = 0
        if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte()) i = 3
        val map = IntArray(bytes.size + 1)
        var n = 0
        while (i < bytes.size) {
            val b = bytes[i].toInt() and 0xFF
            if (b == '\r'.code) {
                // The compiler sees "\r\n" and a lone "\r" as one "\n".
                map[n++] = i
                i += if (i + 1 < bytes.size && bytes[i + 1] == '\n'.code.toByte()) 2 else 1
                continue
            }
            val len = when {
                b < 0x80 -> 1
                b < 0xE0 -> 2
                b < 0xF0 -> 3
                else -> 4
            }
            map[n++] = i
            // A 4-byte sequence is a surrogate pair: two UTF-16 units.
            if (len == 4) map[n++] = i
            i += len
        }
        map[n++] = bytes.size
        charToByte = map.copyOf(n)
    }

    fun byteOffset(charOffset: Int): Int =
        if (charOffset < 0) -1 else charToByte[charOffset.coerceAtMost(charToByte.size - 1)]
}
