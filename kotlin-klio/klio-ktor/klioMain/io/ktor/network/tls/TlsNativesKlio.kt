/*
 * Copyright 2014-2025 JetBrains s.r.o and contributors. Use of this source code is governed by the Apache 2.0 license.
 */

// The host natives behind klio's TLS actuals. Each stub is shadowed by a
// native of the same name over klio's TLS 1.3 engine; a session is a handle
// the Kotlin side feeds the peer's bytes and drains the bytes to send.

package io.ktor.network.tls

internal fun __kktls_client(serverName: String?, trustPem: String?, systemTrust: Boolean, insecure: Boolean): Long = 0L
internal fun __kktls_identity(chainPem: String, keyPem: String): Long = 0L
internal fun __kktls_identity_free(identity: Long) {}
internal fun __kktls_server(identity: Long): Long = 0L
internal fun __kktls_feed(session: Long, bytes: ByteArray, offset: Int, length: Int): Int = -1
internal fun __kktls_take_output(session: Long): ByteArray? = null
internal fun __kktls_read(session: Long, max: Int): ByteArray? = null
internal fun __kktls_write(session: Long, bytes: ByteArray, offset: Int, length: Int): Int = -1
internal fun __kktls_close(session: Long) {}
internal fun __kktls_state(session: Long): Int = 2
internal fun __kktls_error(session: Long): String? = null
internal fun __kktls_free(session: Long) {}
internal fun __kktls_last_error(): String? = null
