/*
 * KLIO actuals for the `kotlin.uuid` platform hooks. All but two delegate to
 * the common implementations; random bytes come from the default RNG and
 * serialization is identity (KLIO has no host serialization).
 */
@file:OptIn(ExperimentalUuidApi::class)

package kotlin.uuid

import kotlin.random.Random

internal actual fun secureRandomBytes(destination: ByteArray) {
    Random.nextBytes(destination)
}

internal actual fun serializedUuid(uuid: Uuid): Any = uuid

internal actual fun ByteArray.getLongAt(index: Int): Long = getLongAtCommonImpl(index)

internal actual fun Long.formatBytesInto(dst: ByteArray, dstOffset: Int, startIndex: Int, endIndex: Int) =
    formatBytesIntoCommonImpl(dst, dstOffset, startIndex, endIndex)

internal actual fun ByteArray.setLongAt(index: Int, value: Long) = setLongAtCommonImpl(index, value)

internal actual fun uuidParseHexDash(hexDashString: String): Uuid = uuidParseHexDashCommonImpl(hexDashString)

internal actual fun uuidParseHexDashOrNull(hexDashString: String): Uuid? = uuidParseHexDashOrNullCommonImpl(hexDashString)

internal actual fun uuidParseHex(hexString: String): Uuid = uuidParseHexCommonImpl(hexString)

internal actual fun uuidParseHexOrNull(hexString: String): Uuid? = uuidParseHexOrNullCommonImpl(hexString)
