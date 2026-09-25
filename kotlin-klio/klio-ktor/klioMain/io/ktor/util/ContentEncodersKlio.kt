/*
 * Copyright 2014-2026 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's gzip and deflate encoders. The posix actuals are the identity
// encoder; these follow the JVM's (EncodersJvm.kt, Deflater.kt), with raw
// DEFLATE and CRC-32 from host natives over Zig's std.compress.flate where
// the JVM uses java.util.zip. The gzip header and trailer are written and
// checked here, as on the JVM. Both directions stream: output is written as
// the input that produces it arrives.

package io.ktor.util

import io.ktor.utils.io.*
import io.ktor.utils.io.bits.*
import io.ktor.utils.io.core.*
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.io.EOFException
import kotlinx.io.IOException
import kotlin.coroutines.CoroutineContext

internal fun __kkz_deflater(): Long = 0L
internal fun __kkz_deflate(handle: Long, bytes: ByteArray, offset: Int, length: Int): ByteArray? = null
internal fun __kkz_deflate_finish(handle: Long): ByteArray? = null
internal fun __kkz_inflater(): Long = 0L
internal fun __kkz_inflate_input(handle: Long, bytes: ByteArray, offset: Int, length: Int): Boolean = false
internal fun __kkz_inflate_finish(handle: Long): Boolean = false
internal fun __kkz_inflate_take(handle: Long, max: Int): ByteArray? = null
internal fun __kkz_inflate_remaining(handle: Long): ByteArray = ByteArray(0)
internal fun __kkz_inflate_error(handle: Long): String? = null
internal fun __kkz_free(handle: Long) {}
internal fun __kkz_crc32(crc: Int, bytes: ByteArray, offset: Int, length: Int): Int = 0

/**
 * Implementation of [ContentEncoder] using gzip algorithm
 *
 * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.util.GZipEncoder)
 */
public actual object GZipEncoder : ContentEncoder, Encoder by GZip {
    actual override val name: String = "gzip"
}

/**
 * Implementation of [ContentEncoder] using deflate algorithm
 *
 * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.util.DeflateEncoder)
 */
public actual object DeflateEncoder : ContentEncoder, Encoder by Deflate {
    actual override val name: String = "deflate"
}

private const val GZIP_HEADER_SIZE: Int = 10
private const val DEFLATED: Int = 8
private const val BUFFER_SIZE: Int = 8192
private const val INCOMPLETE_INPUT: String = "Compressed input is incomplete."

private const val GZIP_MAGIC: Short = 0x8b1f.toShort()
private val GZIP_HEADER_PADDING: ByteArray = ByteArray(7)

// GZIP header flags bits
private object GzipHeaderFlags {

    // Is ASCII
    const val FTEXT = 1 shl 0

    // Has header CRC16
    const val FHCRC = 1 shl 1

    // Extra fields present
    const val EXTRA = 1 shl 2

    // File name present
    const val FNAME = 1 shl 3

    // File comment present
    const val FCOMMENT = 1 shl 4
}

private infix fun Int.has(flag: Int) = this and flag != 0

private val Deflate: Encoder = object : Encoder {
    override fun encode(source: ByteReadChannel, coroutineContext: CoroutineContext): ByteReadChannel =
        source.deflated(gzip = false, coroutineContext = coroutineContext)

    override fun encode(source: ByteWriteChannel, coroutineContext: CoroutineContext): ByteWriteChannel =
        source.deflated(gzip = false, coroutineContext = coroutineContext)

    override fun decode(source: ByteReadChannel, coroutineContext: CoroutineContext): ByteReadChannel =
        inflate(source, gzip = false, coroutineContext = coroutineContext)
}

private val GZip: Encoder = object : Encoder {
    override fun encode(source: ByteReadChannel, coroutineContext: CoroutineContext): ByteReadChannel =
        source.deflated(gzip = true, coroutineContext = coroutineContext)

    override fun encode(source: ByteWriteChannel, coroutineContext: CoroutineContext): ByteWriteChannel =
        source.deflated(gzip = true, coroutineContext = coroutineContext)

    override fun decode(source: ByteReadChannel, coroutineContext: CoroutineContext): ByteReadChannel =
        inflate(source, coroutineContext = coroutineContext)
}

private val InflateWriterCoroutineName = CoroutineName("encoder-inflate-writer")
private val DeflateWriterCoroutineName = CoroutineName("encoder-deflate-writer")
private val DeflateReaderCoroutineName = CoroutineName("encoder-deflate-reader")

@OptIn(DelicateCoroutinesApi::class)
private fun inflate(
    source: ByteReadChannel,
    gzip: Boolean = true,
    coroutineContext: CoroutineContext
): ByteReadChannel = GlobalScope.writer(coroutineContext + InflateWriterCoroutineName) {
    if (gzip) {
        val header = source.readPacket(GZIP_HEADER_SIZE)
        val magic = header.readShortLittleEndian()
        val format = header.readByte()
        val flags = header.readByte().toInt()
        header.discard()

        // skip the extra header if present
        if (flags and GzipHeaderFlags.EXTRA != 0) {
            val extraLen = source.readShort().toLong()
            source.discardExact(extraLen)
        }

        check(magic == GZIP_MAGIC) { "GZIP magic invalid: $magic" }
        check(format.toInt() == DEFLATED) { "Deflater method unsupported: $format." }
        check(!(flags has GzipHeaderFlags.FNAME)) { "Gzip file name not supported" }
        check(!(flags has GzipHeaderFlags.FCOMMENT)) { "Gzip file comment not supported" }

        // skip the header CRC if present
        if (flags has GzipHeaderFlags.FHCRC) {
            source.discardExact(2)
        }
    }

    val inflater = __kkz_inflater()
    val readBuffer = ByteArray(BUFFER_SIZE)
    val totals = InflatedTotals()
    try {
        while (!source.isClosedForRead) {
            val count = source.readAvailable(readBuffer, 0, readBuffer.size)
            if (count <= 0) continue
            if (!__kkz_inflate_input(inflater, readBuffer, 0, count)) throw inflateFailure(inflater)
            channel.writeInflated(inflater, totals)
        }

        source.closedCause?.let { throw it }

        if (!__kkz_inflate_finish(inflater)) throw inflateFailure(inflater)
        channel.writeInflated(inflater, totals)
        val checksum = totals.checksum
        val totalSize = totals.size

        val trailer = __kkz_inflate_remaining(inflater)
        if (gzip) {
            check(trailer.size == 8) {
                "Expected 8 bytes in the trailer. Actual: ${trailer.size} $"
            }

            val expectedChecksum = trailer.intLittleEndianAt(0)
            val expectedSize = trailer.intLittleEndianAt(4)

            check(checksum == expectedChecksum) { "Gzip checksum invalid." }
            check(totalSize == expectedSize) { "Gzip size invalid. Expected $expectedSize, actual $totalSize" }
        } else {
            check(trailer.isEmpty())
        }
    } finally {
        __kkz_free(inflater)
    }
}.channel

/** The CRC-32 and size of what an inflater has produced. */
private class InflatedTotals {
    var checksum: Int = 0
    var size: Int = 0
}

/** Writes the inflater's pending output to the channel. */
private suspend fun ByteWriteChannel.writeInflated(inflater: Long, totals: InflatedTotals) {
    while (true) {
        val chunk = __kkz_inflate_take(inflater, BUFFER_SIZE) ?: return
        totals.checksum = __kkz_crc32(totals.checksum, chunk, 0, chunk.size)
        totals.size += chunk.size
        writeFully(chunk)
    }
}

/**
 * Truncated input is an EOFException, as on the JVM. Invalid input is an
 * IOException carrying zlib's message, where the JVM throws a
 * DataFormatException.
 */
private fun inflateFailure(inflater: Long): Throwable {
    val message = __kkz_inflate_error(inflater) ?: INCOMPLETE_INPUT
    return if (message == INCOMPLETE_INPUT) EOFException(message) else IOException(message)
}

private fun ByteArray.intLittleEndianAt(index: Int): Int =
    (this[index].toInt() and 0xff) or
        ((this[index + 1].toInt() and 0xff) shl 8) or
        ((this[index + 2].toInt() and 0xff) shl 16) or
        ((this[index + 3].toInt() and 0xff) shl 24)

private suspend fun ByteWriteChannel.putGzipHeader() {
    writeShort(GZIP_MAGIC.reverseByteOrder())
    writeByte(DEFLATED.toByte())
    writeFully(GZIP_HEADER_PADDING)
}

private suspend fun ByteWriteChannel.putGzipTrailer(crc: Int, totalIn: Int) {
    writeInt(crc.reverseByteOrder())
    writeInt(totalIn.reverseByteOrder())
}

/**
 * Does deflate compression
 * optionally doing CRC and writing GZIP header and trailer if [gzip] = `true`
 */
private suspend fun ByteReadChannel.deflateTo(
    destination: ByteWriteChannel,
    gzip: Boolean = true
) {
    val deflater = __kkz_deflater()
    val input = ByteArray(BUFFER_SIZE)
    var crc = 0
    var totalIn = 0

    try {
        if (gzip) {
            destination.putGzipHeader()
        }

        while (!isClosedForRead) {
            val count = readAvailable(input, 0, input.size)
            if (count <= 0) continue

            crc = __kkz_crc32(crc, input, 0, count)
            totalIn += count
            __kkz_deflate(deflater, input, 0, count)?.let { destination.writeFully(it) }
        }

        closedCause?.let { throw it }

        __kkz_deflate_finish(deflater)?.let { destination.writeFully(it) }

        if (gzip) {
            destination.putGzipTrailer(crc, totalIn)
        }
    } finally {
        __kkz_free(deflater)
    }
}

/**
 * Launch a coroutine on [coroutineContext] that does deflate compression
 * optionally doing CRC and writing GZIP header and trailer if [gzip] = `true`
 */
@OptIn(DelicateCoroutinesApi::class)
private fun ByteReadChannel.deflated(
    gzip: Boolean = true,
    coroutineContext: CoroutineContext = Dispatchers.Unconfined
): ByteReadChannel = GlobalScope.writer(coroutineContext + DeflateWriterCoroutineName, autoFlush = true) {
    this@deflated.deflateTo(channel, gzip)
}.channel

/**
 * Launch a coroutine on [coroutineContext] that does deflate compression
 * optionally doing CRC and writing GZIP header and trailer if [gzip] = `true`
 */
@OptIn(DelicateCoroutinesApi::class)
private fun ByteWriteChannel.deflated(
    gzip: Boolean = true,
    coroutineContext: CoroutineContext = Dispatchers.Unconfined
): ByteWriteChannel = GlobalScope.reader(coroutineContext + DeflateReaderCoroutineName, autoFlush = true) {
    channel.deflateTo(this@deflated, gzip)
}.channel
