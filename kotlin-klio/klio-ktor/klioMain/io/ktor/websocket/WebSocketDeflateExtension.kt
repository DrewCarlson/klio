/*
 * Copyright 2014-2021 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's permessage-deflate (RFC 7692), a port of upstream's JVM extension:
// the negotiation and the frame rules are upstream's. java.util.zip's
// Deflater and Inflater are replaced by klio's DEFLATE natives: each outgoing
// message is compressed on its own, which the RFC allows whatever the context
// takeover negotiated, and each incoming message is inflated after the
// stream's earlier output (the window), kept here unless the peer drops its
// context.

package io.ktor.websocket

import io.ktor.util.*
import kotlinx.io.IOException

private const val SERVER_MAX_WINDOW_BITS: String = "server_max_window_bits"
private const val CLIENT_NO_CONTEXT_TAKEOVER = "client_no_context_takeover"
private const val SERVER_NO_CONTEXT_TAKEOVER = "server_no_context_takeover"
private const val CLIENT_MAX_WINDOW_BITS = "client_max_window_bits"
private const val PERMESSAGE_DEFLATE = "permessage-deflate"

private const val MAX_WINDOW_BITS: Int = 15
private const val MIN_WINDOW_BITS: Int = 8
internal const val MAX_INFLATED_FRAME_SIZE: Int = 256 * 1024 * 1024 // 256 MiB

/** java.util.zip.Deflater.DEFAULT_COMPRESSION. */
private const val DEFAULT_COMPRESSION: Int = -1

/** The LZ77 window a message may reach back into. */
private const val WINDOW_SIZE: Int = 1 shl MAX_WINDOW_BITS

private val PADDED_EMPTY_CHUNK: ByteArray = byteArrayOf(0, 0, 0, 0xff.toByte(), 0xff.toByte())
private val EMPTY_CHUNK: ByteArray = byteArrayOf(0, 0, 0xff.toByte(), 0xff.toByte())

/**
 * Compress and decompress WebSocket frames to reduce amount of transferred bytes.
 *
 * Usage
 * ```kotlin
 * install(WebSockets) {
 *     extensions {
 *         install(WebSocketDeflateExtension)
 *     }
 * }
 * ```
 *
 * Implements WebSocket deflate extension from [RFC-7692](https://tools.ietf.org/html/rfc7692).
 * This implementation is using window size = 15 as upstream does.
 *
 * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.websocket.WebSocketDeflateExtension)
 */
public class WebSocketDeflateExtension internal constructor(
    private val config: Config
) : WebSocketExtension<WebSocketDeflateExtension.Config> {
    override val factory: WebSocketExtensionFactory<Config, out WebSocketExtension<Config>> = WebSocketDeflateExtension

    override val protocols: List<WebSocketExtensionHeader> = config.build()

    init {
        require(config.compressionLevel in DEFAULT_COMPRESSION..9) { "invalid compression level" }
    }

    /** The stream's output so far, up to a window, for the next message. */
    private var incomingHistory: ByteArray = ByteArray(0)

    internal var outgoingNoContextTakeover: Boolean = false
    internal var incomingNoContextTakeover: Boolean = false

    /**
     * Deflater state for incoming frames. Specified if frames should be decompressed until fin packet.
     */
    private var decompressIncoming: Boolean = false

    override fun clientNegotiation(negotiatedProtocols: List<WebSocketExtensionHeader>): Boolean {
        val protocol = negotiatedProtocols.find { it.name == PERMESSAGE_DEFLATE } ?: return false

        incomingNoContextTakeover = config.serverNoContextTakeOver
        outgoingNoContextTakeover = config.clientNoContextTakeOver

        for ((key, value) in protocol.parseParameters()) {
            when (key) {
                SERVER_MAX_WINDOW_BITS -> {
                    // This value is a hint for a client and can be ignored.
                }

                CLIENT_MAX_WINDOW_BITS -> {
                    if (value.isBlank()) continue
                    check(value.toInt() == MAX_WINDOW_BITS) { "Only $MAX_WINDOW_BITS window size is supported." }
                }

                SERVER_NO_CONTEXT_TAKEOVER -> {
                    check(value.isBlank()) {
                        "WebSocket $PERMESSAGE_DEFLATE extension parameter $SERVER_NO_CONTEXT_TAKEOVER shouldn't " +
                            "have a value. Current: $value"
                    }

                    incomingNoContextTakeover = true
                }

                CLIENT_NO_CONTEXT_TAKEOVER -> {
                    check(value.isBlank()) {
                        "WebSocket $PERMESSAGE_DEFLATE extension parameter $CLIENT_NO_CONTEXT_TAKEOVER shouldn't " +
                            "have a value. Current: $value"
                    }

                    outgoingNoContextTakeover = true
                }
            }
        }

        return true
    }

    override fun serverNegotiation(requestedProtocols: List<WebSocketExtensionHeader>): List<WebSocketExtensionHeader> {
        val protocol = requestedProtocols.find { it.name == PERMESSAGE_DEFLATE } ?: return emptyList()
        val parameters = mutableListOf<String>()

        for ((key, value) in protocol.parseParameters()) {
            when (key.lowercase()) {
                SERVER_MAX_WINDOW_BITS -> {
                    check(value.toInt() == MAX_WINDOW_BITS) { "Only $MAX_WINDOW_BITS window size is supported" }
                }

                CLIENT_MAX_WINDOW_BITS -> {
                    // This value is a hint for a server and can be ignored.
                }

                SERVER_NO_CONTEXT_TAKEOVER -> {
                    check(value.isBlank())

                    outgoingNoContextTakeover = true
                    parameters.add(SERVER_NO_CONTEXT_TAKEOVER)
                }

                CLIENT_NO_CONTEXT_TAKEOVER -> {
                    check(value.isBlank())

                    incomingNoContextTakeover = true
                    parameters.add(CLIENT_NO_CONTEXT_TAKEOVER)
                }

                else -> error("Unsupported extension parameter: ($key, $value)")
            }
        }

        return listOf(WebSocketExtensionHeader(PERMESSAGE_DEFLATE, parameters))
    }

    override fun processOutgoingFrame(frame: Frame): Frame {
        if (frame !is Frame.Text && frame !is Frame.Binary) return frame
        if (!config.compressCondition(frame)) return frame

        val deflated = deflateMessage(frame.data, config.compressionLevel)

        return Frame.byType(frame.fin, frame.frameType, deflated, rsv1, frame.rsv2, frame.rsv3)
    }

    override fun processIncomingFrame(frame: Frame): Frame {
        if (!frame.isCompressed() && !decompressIncoming) return frame
        decompressIncoming = true

        val inflated = inflateMessage(incomingHistory, frame.data, config.maxInflatedFrameSize)
        incomingHistory = if (incomingNoContextTakeover) ByteArray(0) else window(incomingHistory, inflated)

        if (frame.fin) {
            decompressIncoming = false
        }

        return Frame.byType(frame.fin, frame.frameType, inflated, !rsv1, frame.rsv2, frame.rsv3)
    }

    /**
     * WebSocket deflate extension configuration.
     *
     * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.websocket.WebSocketDeflateExtension.Config)
     */
    public class Config {
        /**
         * Specify if the client drops the deflater state (reset the window) after each frame.
         *
         * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.websocket.WebSocketDeflateExtension.Config.clientNoContextTakeOver)
         */
        public var clientNoContextTakeOver: Boolean = false

        /**
         * Specify if the server drops the deflater state (reset the window) after each frame.
         *
         * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.websocket.WebSocketDeflateExtension.Config.serverNoContextTakeOver)
         */
        public var serverNoContextTakeOver: Boolean = false

        /**
         * Compression level that is used for outgoing frames: -1 for the default (6), 0 to store, 1 to 9.
         *
         * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.websocket.WebSocketDeflateExtension.Config.compressionLevel)
         */
        public var compressionLevel: Int = DEFAULT_COMPRESSION

        /**
         * Maximum inflated size of an inbound frame.
         *
         * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.websocket.WebSocketDeflateExtension.Config.maxInflatedFrameSize)
         */
        public var maxInflatedFrameSize: Int = MAX_INFLATED_FRAME_SIZE

        internal var manualConfig: (MutableList<WebSocketExtensionHeader>) -> Unit = {}

        internal var compressCondition: (Frame) -> Boolean = { true }

        /**
         * Configure which protocols should send the client.
         *
         * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.websocket.WebSocketDeflateExtension.Config.configureProtocols)
         */
        public fun configureProtocols(block: (protocols: MutableList<WebSocketExtensionHeader>) -> Unit) {
            val old = manualConfig
            manualConfig = {
                old(it)
                block(it)
            }
        }

        /**
         * Indicates if the outgoing frame should be compressed.
         *
         * Compress the frame only if all conditions passed.
         *
         * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.websocket.WebSocketDeflateExtension.Config.compressIf)
         */
        public fun compressIf(block: (frame: Frame) -> Boolean) {
            val old = compressCondition
            compressCondition = { block(it) && old(it) }
        }

        /**
         * Specify the minimum size of frame for compression.
         *
         * [Report a problem](https://ktor.io/feedback/?fqname=io.ktor.websocket.WebSocketDeflateExtension.Config.compressIfBiggerThan)
         */
        public fun compressIfBiggerThan(bytes: Int) {
            compressIf { frame -> frame.data.size > bytes }
        }

        internal fun build(): List<WebSocketExtensionHeader> {
            val result = mutableListOf<WebSocketExtensionHeader>()

            val parameters = mutableListOf<String>()

            if (clientNoContextTakeOver) {
                parameters += CLIENT_NO_CONTEXT_TAKEOVER
            }

            if (serverNoContextTakeOver) {
                parameters += SERVER_NO_CONTEXT_TAKEOVER
            }

            result += WebSocketExtensionHeader(PERMESSAGE_DEFLATE, parameters)
            manualConfig(result)
            return result
        }
    }

    public companion object : WebSocketExtensionFactory<Config, WebSocketDeflateExtension> {
        override val key: AttributeKey<WebSocketDeflateExtension> = AttributeKey("WebsocketDeflateExtension")
        override val rsv1: Boolean = true
        override val rsv2: Boolean = false
        override val rsv3: Boolean = false

        override fun install(config: Config.() -> Unit): WebSocketDeflateExtension =
            WebSocketDeflateExtension(Config().apply(config))
    }
}

private fun Frame.isCompressed(): Boolean = rsv1 && (this is Frame.Text || this is Frame.Binary)

/**
 * Compresses one message and applies RFC 7692's framing as upstream does: a
 * message ending in an empty stored block drops that block's last four bytes;
 * otherwise a zero byte starts the empty block the receiver completes.
 */
private fun deflateMessage(data: ByteArray, level: Int): ByteArray {
    val deflated = __kkz_deflate_message(data, 0, data.size, level)
        ?: throw IllegalArgumentException("invalid compression level")
    if (deflated.endsWith(PADDED_EMPTY_CHUNK)) {
        return deflated.copyOf(deflated.size - EMPTY_CHUNK.size)
    }
    return deflated + 0.toByte()
}

private fun inflateMessage(history: ByteArray, data: ByteArray, maxOutputSize: Int): ByteArray {
    require(maxOutputSize >= 0) { "maxOutputSize should be >= 0" }
    return when (val result = __kkz_inflate_message(history, data, 0, data.size, maxOutputSize)) {
        is ByteArray -> result
        is String -> throw IOException(result)
        else -> throw IOException("Inflater made no progress; data probably corrupted")
    }
}

private fun window(history: ByteArray, output: ByteArray): ByteArray {
    val combined = history + output
    return if (combined.size <= WINDOW_SIZE) combined else combined.copyOfRange(combined.size - WINDOW_SIZE, combined.size)
}

private fun ByteArray.endsWith(suffix: ByteArray): Boolean {
    if (size < suffix.size) return false
    for (i in suffix.indices) {
        if (this[size - suffix.size + i] != suffix[i]) return false
    }
    return true
}
