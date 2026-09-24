// klio `actual` for the ktor-io `ByteOrder` expect. The posix actual reads
// `kotlin.native.Platform.isLittleEndian`; every host klio runs on (x86-64 and
// AArch64) is little-endian, which is what the JVM's
// `java.nio.ByteOrder.nativeOrder()` reports there.

package io.ktor.utils.io.core

public actual enum class ByteOrder {
    BIG_ENDIAN,
    LITTLE_ENDIAN;

    public actual companion object {
        public actual fun nativeOrder(): ByteOrder = LITTLE_ENDIAN
    }
}
