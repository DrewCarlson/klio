// Internal hex helper shared by the shim. The engine sends binary
// response bodies hex-encoded so they survive the flat-String
// transport; this helper decodes them back into ByteArray for the
// HttpResponse.bodyBytes field.

package io.ktor.http

internal fun __kktor_hexToBytes(hex: String): ByteArray {
    if (hex.length % 2 != 0) return ByteArray(0)
    val out = ByteArray(hex.length / 2)
    val table = "0123456789abcdef"
    for (i in 0 until out.size) {
        val hi = table.indexOf(hex[i * 2].lowercaseChar())
        val lo = table.indexOf(hex[i * 2 + 1].lowercaseChar())
        if (hi < 0 || lo < 0) return ByteArray(0)
        out[i] = ((hi shl 4) or lo).toByte()
    }
    return out
}
