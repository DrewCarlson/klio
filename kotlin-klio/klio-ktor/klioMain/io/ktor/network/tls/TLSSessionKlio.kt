/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// klio's TLS sessions over a connected socket, client and server. The
// handshake and record protection run in klio's TLS 1.3 engine; this file
// pumps bytes between the socket's channels and the engine, and wraps the
// socket so its channels carry plaintext, as the JVM actual's TLSSocket does.

package io.ktor.network.tls

import io.ktor.network.sockets.*
import io.ktor.utils.io.*
import io.ktor.utils.io.core.*
import kotlinx.atomicfu.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.*
import kotlin.coroutines.*

internal actual suspend fun openTLSSession(
    socket: Socket,
    input: ByteReadChannel,
    output: ByteWriteChannel,
    config: TLSConfig,
    context: CoroutineContext
): Socket {
    val trust = config.trustedCertificates.joinToString("\n").ifEmpty { null }
    val handle = __kktls_client(
        config.serverName,
        trust,
        config.useSystemTrustStore,
        config.insecureAcceptAnyCertificate,
    )
    if (handle == 0L) throw TlsException(__kktls_last_error() ?: "the TLS client configuration was refused")
    return startSession(KlioTlsEngine(handle), socket, input, output, context)
}

/**
 * A server's certificate chain and private key, from PEM. The key is a P-256
 * ECDSA, Ed25519 or RSA (2048 to 4096 bits) key, unencrypted, as PKCS#8
 * (`BEGIN PRIVATE KEY`), SEC 1 for P-256 (`BEGIN EC PRIVATE KEY`) or PKCS#1
 * for RSA (`BEGIN RSA PRIVATE KEY`); the chain lists the server's
 * certificate first. An RSA key signs the handshake with RSA-PSS.
 */
public class TlsServerIdentity(certificateChainPem: String, privateKeyPem: String) : Closeable {
    internal val handle: Long = __kktls_identity(certificateChainPem, privateKeyPem).also {
        if (it == 0L) throw TlsException(__kktls_last_error() ?: "the server certificate or key was refused")
    }

    override fun close() {
        __kktls_identity_free(handle)
    }
}

/**
 * Runs the server side of a TLS handshake on this connected socket, and
 * returns a socket whose channels carry the decrypted connection.
 */
public suspend fun Socket.tlsServer(identity: TlsServerIdentity, coroutineContext: CoroutineContext): Socket {
    val reader = openReadChannel()
    val writer = openWriteChannel()
    val handle = __kktls_server(identity.handle)
    if (handle == 0L) {
        close()
        throw TlsException(__kktls_last_error() ?: "the TLS server session was refused")
    }
    return try {
        startSession(KlioTlsEngine(handle), this, reader, writer, coroutineContext)
    } catch (cause: Throwable) {
        reader.cancel(cause)
        writer.close(cause)
        close()
        throw cause
    }
}

private suspend fun startSession(
    engine: KlioTlsEngine,
    socket: Socket,
    input: ByteReadChannel,
    output: ByteWriteChannel,
    context: CoroutineContext
): Socket {
    try {
        engine.handshake(input, output)
    } catch (cause: Throwable) {
        engine.free()
        throw cause
    }
    return KlioTlsSocket(engine, socket, input, output, context)
}

private const val STATE_HANDSHAKE_DONE = 1
private const val STATE_FAILED = 2
private const val STATE_PEER_CLOSED = 4
private const val STATE_FAILED_LOCALLY = 8

/** The alerts that mean the peer's certificate was not accepted. */
private val CERTIFICATE_ALERTS = setOf(42, 43, 44, 45, 46, 48)

private const val RECORD_BUFFER = 16 * 1024 + 512

/** One session handle, used by the handshake and then both socket loops. */
internal class KlioTlsEngine(private val handle: Long) {
    // Records leave in the order the engine queued them.
    private val sending = Mutex()

    fun state(): Int = __kktls_state(handle)

    fun failure(): Throwable {
        val state = state()
        val message = __kktls_error(handle) ?: "the TLS session failed"
        val alert = (state shr 16) and 0xff
        return if (state and STATE_FAILED_LOCALLY != 0 && alert in CERTIFICATE_ALERTS) {
            TlsPeerUnverifiedException(message)
        } else {
            TlsException(message)
        }
    }

    suspend fun flush(output: ByteWriteChannel) {
        sending.withLock {
            val bytes = __kktls_take_output(handle) ?: return
            output.writeFully(bytes)
            output.flush()
        }
    }

    fun feed(bytes: ByteArray, length: Int): Boolean = __kktls_feed(handle, bytes, 0, length) == 0

    fun read(max: Int): ByteArray? = __kktls_read(handle, max)

    fun write(bytes: ByteArray, length: Int): Boolean = __kktls_write(handle, bytes, 0, length) == 0

    fun close() {
        __kktls_close(handle)
    }

    fun free() {
        __kktls_free(handle)
    }

    suspend fun handshake(input: ByteReadChannel, output: ByteWriteChannel) {
        val buffer = ByteArray(RECORD_BUFFER)
        while (true) {
            flush(output)
            val state = state()
            if (state and STATE_FAILED != 0) throw failure()
            if (state and STATE_HANDSHAKE_DONE != 0) return
            val count = input.readAvailable(buffer, 0, buffer.size)
            if (count == -1) throw TlsException("the connection closed during the TLS handshake")
            if (!feed(buffer, count)) {
                // The alert goes out before the failure is reported.
                runCatching { flush(output) }
                throw failure()
            }
        }
    }
}

private class KlioTlsSocket(
    private val engine: KlioTlsEngine,
    private val socket: Socket,
    private val input: ByteReadChannel,
    private val output: ByteWriteChannel,
    override val coroutineContext: CoroutineContext
) : CoroutineScope, Socket by socket {
    private val closed = atomic(false)
    private val inputLoop = atomic<WriterJob?>(null)
    private val outputLoop = atomic<ReaderJob?>(null)

    override fun attachForReading(channel: ByteChannel): WriterJob =
        writer(coroutineContext + CoroutineName("cio-tls-input-loop"), channel) {
            appDataInputLoop(this.channel)
        }.also { inputLoop.value = it }

    override fun attachForWriting(channel: ByteChannel): ReaderJob =
        reader(coroutineContext + CoroutineName("cio-tls-output-loop"), channel) {
            appDataOutputLoop(this.channel)
        }.also { outputLoop.value = it }

    private suspend fun appDataInputLoop(pipe: ByteWriteChannel) {
        val buffer = ByteArray(RECORD_BUFFER)
        try {
            while (true) {
                // Data the handshake's last read carried comes first.
                while (true) {
                    val data = engine.read(buffer.size) ?: break
                    pipe.writeFully(data)
                }
                pipe.flush()
                val state = engine.state()
                if (state and STATE_PEER_CLOSED != 0) break
                if (state and STATE_FAILED != 0) throw engine.failure()
                val count = input.readAvailable(buffer, 0, buffer.size)
                if (count == -1) break
                val fed = engine.feed(buffer, count)
                // Key update answers and alerts.
                engine.flush(output)
                if (!fed) throw engine.failure()
            }
        } catch (_: Throwable) {
        } finally {
            pipe.flushAndClose()
        }
    }

    private suspend fun appDataOutputLoop(pipe: ByteReadChannel) {
        val buffer = ByteArray(RECORD_BUFFER)
        try {
            while (true) {
                val count = pipe.readAvailable(buffer, 0, buffer.size)
                if (count == -1) break
                if (!engine.write(buffer, count)) break
                engine.flush(output)
            }
        } catch (_: ClosedWriteChannelException) {
            // The socket was already closed.
        } finally {
            engine.close()
            runCatching { engine.flush(output) }
            output.flushAndClose()
        }
    }

    override fun dispose() {
        close()
    }

    /**
     * The data written so far and the close_notify alert go out before the
     * connection closes, as the JVM's TLSSocket has it, and the session is
     * freed once neither loop uses it.
     */
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        launch(NonCancellable + CoroutineName("cio-tls-close")) {
            outputLoop.value?.let {
                runCatching { it.channel.flushAndClose() }
                it.job.join()
            }
            socket.close()
            inputLoop.value?.job?.cancelAndJoin()
            engine.free()
        }
    }
}
