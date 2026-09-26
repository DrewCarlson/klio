/*
 * Copyright 2026 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// java.io's InputStream under klio's name: a source of bytes read in order,
// for the APIs that take one (Compose's resource loaders), and the stream
// over a byte array.

package klio.io

/** A source of bytes read in order, until it ends. */
abstract class InputStream : AutoCloseable {
    /** The next byte, 0 to 255, or -1 at the end of the stream. */
    abstract fun read(): Int

    /** Reads up to [b]'s size bytes into it; the number read, or -1 at the end of the stream. */
    open fun read(b: ByteArray): Int = read(b, 0, b.size)

    /** Reads up to [len] bytes into [b] from [off]; the number read, or -1 at the end of the stream. */
    open fun read(b: ByteArray, off: Int, len: Int): Int {
        if (off < 0 || len < 0 || len > b.size - off) throw IndexOutOfBoundsException("off $off, len $len, size ${b.size}")
        if (len == 0) return 0
        var c = read()
        if (c == -1) return -1
        b[off] = c.toByte()
        var n = 1
        while (n < len) {
            c = read()
            if (c == -1) break
            b[off + n] = c.toByte()
            n++
        }
        return n
    }

    /** Every byte left in the stream. */
    open fun readAllBytes(): ByteArray = readNBytes(Int.MAX_VALUE)

    /** Up to [len] bytes, fewer at the end of the stream. */
    open fun readNBytes(len: Int): ByteArray {
        require(len >= 0) { "len < 0" }
        val out = ArrayList<ByteArray>()
        var total = 0
        var remaining = len
        while (remaining > 0) {
            val buf = ByteArray(minOf(remaining, 8192))
            val n = read(buf, 0, buf.size)
            if (n < 0) break
            out.add(if (n == buf.size) buf else buf.copyOf(n))
            total += n
            remaining -= n
        }
        val result = ByteArray(total)
        var at = 0
        for (part in out) {
            part.copyInto(result, at)
            at += part.size
        }
        return result
    }

    /** Skips up to [n] bytes; the number skipped. */
    open fun skip(n: Long): Long {
        var skipped = 0L
        while (skipped < n && read() != -1) skipped++
        return skipped
    }

    /** The number of bytes that can be read without blocking. */
    open fun available(): Int = 0

    override fun close() {}

    companion object {
        /** A stream with no bytes. */
        fun nullInputStream(): InputStream = ByteArrayInputStream(ByteArray(0))
    }
}

/** The bytes of [buf] from [offset], [length] of them, as a stream. */
open class ByteArrayInputStream(
    private val buf: ByteArray,
    offset: Int = 0,
    length: Int = buf.size,
) : InputStream() {
    private var pos = offset
    private val end = minOf(offset + length, buf.size)

    override fun read(): Int = if (pos < end) buf[pos++].toInt() and 0xFF else -1

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (off < 0 || len < 0 || len > b.size - off) throw IndexOutOfBoundsException("off $off, len $len, size ${b.size}")
        if (pos >= end) return -1
        val n = minOf(len, end - pos)
        buf.copyInto(b, off, pos, pos + n)
        pos += n
        return n
    }

    override fun readAllBytes(): ByteArray {
        val out = buf.copyOfRange(pos, end)
        pos = end
        return out
    }

    override fun skip(n: Long): Long {
        val k = minOf(n, (end - pos).toLong()).coerceAtLeast(0L)
        pos += k.toInt()
        return k
    }

    override fun available(): Int = end - pos
}
